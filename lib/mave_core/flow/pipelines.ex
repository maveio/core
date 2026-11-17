defmodule MaveCore.Flow.Pipelines do
  @moduledoc """
  The versioned encoding pipeline of a space.

  A space starts from a flow (its default flow template, or the platform
  default) and may save overrides on top of it: optional steps turned off and
  step settings changed. Each save is a new `MaveCore.Flow.PipelineVersion`.

  New runs for the space use the newest version. `for_run/3` applies it to the
  flow version a run would otherwise use and stores the result as an immutable
  flow version of a template derived for the space, so earlier runs keep the
  definition they ran with.
  """
  import Ecto.Query

  alias MaveCore.Flow

  alias MaveCore.Flow.{
    Pipeline,
    PipelineVersion,
    Presets,
    Run,
    StepRegistry,
    StepRun,
    Template,
    Version
  }

  alias MaveCore.LegacyShortUUID
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  require Logger

  @default_template "publish_default"
  @save_attempts 3

  @doc "Whether the space may change its pipeline. Allowed unless the host manages it."
  def can_edit?(%Space{} = space), do: UsageLimits.can_edit_encoding_pipeline?(space)

  @doc """
  Plugin step types the space cannot add to its pipeline, with the reason:
  the installation cannot run the step, or the host does not allow it.
  """
  def unavailable_steps(%Space{} = space) do
    for %{"type" => type, "plugin" => true} <- StepRegistry.all(),
        reason = unavailable_reason(space, type),
        into: %{},
        do: {type, reason}
  end

  defp unavailable_reason(space, type) do
    with :ok <- StepRegistry.availability(type),
         :ok <- UsageLimits.can_use_encoding_step?(space, type) do
      nil
    else
      {:unavailable, reason} ->
        reason

      {:error, reason} ->
        Map.get(
          UsageLimits.restriction_copy(:encoding_step, reason),
          :notice,
          "This step is not included for this space."
        )
    end
  end

  @recent_step_runs 60

  @doc """
  What the plugin steps of the space's most recent uploads did, by step id:
  `%{status, progress, results, reason, at}`. `results` are the values the step
  type asks to show (`MaveCore.Flow.StepRegistry.results/2`); `progress` is a
  percentage while the step runs.
  """
  def step_activity(%Space{hash: space_hash}) do
    case for %{"type" => type, "plugin" => true} <- StepRegistry.all(), do: type do
      [] ->
        %{}

      types ->
        StepRun
        |> join(:inner, [step_run], run in Run, on: run.id == step_run.flow_run_id)
        |> where(
          [step_run, run],
          step_run.step_type in ^types and
            step_run.status in ["executing", "succeeded", "failed"] and
            fragment("?->>'space_hash' = ?", run.input, ^space_hash)
        )
        |> order_by([step_run], desc: step_run.updated_at)
        |> limit(@recent_step_runs)
        |> Repo.all()
        |> Enum.reduce(%{}, fn step_run, activity ->
          Map.put_new(activity, step_run.step_id, describe_activity(step_run))
        end)
    end
  end

  defp describe_activity(%StepRun{} = step_run) do
    output = step_run.output || %{}

    %{
      status: step_run.status,
      progress: get_in(step_run.execution_metadata || %{}, ["progress", "percent"]),
      progress_label: StepRegistry.progress_label(step_run.step_type),
      results: StepRegistry.results(step_run.step_type, output),
      reason: if(output["status"] in ["skipped", "unavailable"], do: output["reason"]),
      at: step_run.completed_at || step_run.updated_at
    }
  end

  @doc """
  The flow new uploads of the space start from, before overrides: its template
  slug and current definition.
  """
  def base(%Space{} = space) do
    slug = base_template(space)

    case Presets.fetch(slug) do
      {:ok, preset} ->
        {:ok, %{template: slug, name: preset["name"], definition: preset["definition"]}}

      {:error, :preset_not_found} ->
        with {:ok, template, version} <- Flow.fetch_active_version(slug) do
          {:ok, %{template: slug, name: template.name, definition: version.definition}}
        end
    end
  end

  @doc "The newest saved version of the space's pipeline, if any."
  def current(%Space{id: space_id}) do
    PipelineVersion
    |> where([pipeline], pipeline.space_id == ^space_id)
    |> order_by([pipeline], desc: pipeline.version)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The overrides new uploads of the space use."
  def current_overrides(%Space{} = space) do
    case current(space) do
      %PipelineVersion{overrides: overrides} -> Pipeline.normalize(overrides)
      nil -> Pipeline.empty()
    end
  end

  @doc "Saved versions of the space's pipeline, newest first."
  def list_versions(%Space{id: space_id}, limit \\ 20) do
    PipelineVersion
    |> where([pipeline], pipeline.space_id == ^space_id)
    |> order_by([pipeline], desc: pipeline.version)
    |> limit(^limit)
    |> preload(:created_by)
    |> Repo.all()
  end

  def get_version(%Space{id: space_id}, version) when is_integer(version) do
    Repo.get_by(PipelineVersion, space_id: space_id, version: version)
  end

  @doc """
  Validates overrides against the space's flow and saves them as the next
  version. Options: `:user` (who saved it) and `:note`.

  Returns `{:error, :unchanged}` when the overrides equal the current version
  and `{:error, {:invalid, issues}}` when they break a dependency rule.
  """
  def save(%Space{} = space, overrides, opts \\ []) do
    overrides = Pipeline.normalize(overrides)

    with :ok <- can_edit?(space),
         {:ok, base} <- base(space),
         {:ok, _definition} <- validate(space, base.definition, overrides),
         :ok <- ensure_changed(space, overrides) do
      insert_version(space, overrides, opts, @save_attempts)
    end
  end

  @doc """
  Chooses the flow template and version a run should use.

  Runs started with `space_pipeline: %Space{}` get the space's overrides applied
  to the selected version. Runs without the option, with a pinned `:version`, or
  for a space without overrides use the selected version unchanged. Overrides
  that no longer fit the flow are skipped rather than failing the upload, and
  add-on steps that became unavailable are left out.
  """
  def for_run(%Template{} = template, %Version{} = version, opts) do
    with %Space{} = space <- Keyword.get(opts, :space_pipeline),
         nil <- Keyword.get(opts, :version),
         %PipelineVersion{} = pipeline <- current(space),
         overrides = Pipeline.normalize(pipeline.overrides),
         false <- Pipeline.empty?(overrides) do
      apply_to_run(space, pipeline, overrides, template, version)
    else
      _ -> {template, version}
    end
  end

  defp apply_to_run(space, pipeline, overrides, template, version) do
    overrides = drop_unavailable_steps(space, version.definition, overrides)

    case Pipeline.apply(version.definition, overrides) do
      {:ok, definition} when definition == version.definition ->
        {template, version}

      {:ok, definition} ->
        definition =
          Map.put(definition, "pipeline", %{
            "space_hash" => space.hash,
            "version" => pipeline.version,
            "base_template" => template.slug,
            "base_version" => version.version
          })

        case derive_version(space, template, definition) do
          {:ok, derived_template, derived_version} ->
            {derived_template, derived_version}

          {:error, reason} ->
            Logger.warning(
              "Could not store the pipeline of space #{space.hash}; using #{template.slug}: #{inspect(reason)}"
            )

            {template, version}
        end

      {:error, issues} ->
        Logger.warning(
          "Pipeline v#{pipeline.version} of space #{space.hash} does not fit #{template.slug} v#{version.version}; " <>
            "using the flow unchanged: #{Enum.map_join(issues, " ", & &1.message)}"
        )

        {template, version}
    end
  end

  defp drop_unavailable_steps(_space, _definition, %{"added_steps" => []} = overrides),
    do: overrides

  defp drop_unavailable_steps(space, definition, overrides) do
    unavailable = unavailable_steps(space)

    definition
    |> Pipeline.resolve(overrides, unavailable: unavailable)
    |> Map.fetch!(:steps)
    |> Enum.filter(&(&1.addon and &1.state == :enabled and not &1.available))
    |> Enum.reduce(overrides, &Pipeline.put_step_added(&2, &1.id, false))
  end

  defp derive_version(space, template, definition) do
    with {:ok, derived_template} <- derived_template(space, template),
         {:ok, version} <- find_or_create_version(derived_template, definition) do
      {:ok, derived_template, version}
    end
  end

  # A concurrent upload may store the same template or version first, so a
  # failed insert is followed by a second lookup.
  defp find_or_create_version(template, definition) do
    checksum = Flow.definition_checksum(definition)

    with nil <- matching_version(template.id, checksum),
         {:error, reason} <- Flow.create_version(template, %{"definition" => definition}),
         nil <- matching_version(template.id, checksum) do
      {:error, reason}
    else
      %Version{} = version -> {:ok, version}
      {:ok, %Version{} = version} -> {:ok, version}
    end
  end

  defp derived_template(%Space{} = space, %Template{} = template) do
    slug = derived_slug(space, template)

    attrs = %{
      slug: slug,
      name: "#{template.name} (space #{space.hash})",
      description: "Pipeline of space #{space.hash}, derived from #{template.slug}."
    }

    with nil <- Repo.get_by(Template, slug: slug),
         {:error, changeset} <- Flow.create_template(attrs),
         nil <- Repo.get_by(Template, slug: slug) do
      {:error, changeset}
    else
      %Template{} = derived -> {:ok, derived}
      {:ok, %Template{} = derived} -> {:ok, derived}
    end
  end

  @doc "Slug of the template that holds a space's versions of `template`."
  def derived_slug(%Space{id: space_id}, %Template{slug: slug}) do
    {:ok, uuid} = LegacyShortUUID.decode(space_id)
    "#{slug}.space-#{String.replace(uuid, "-", "")}"
  end

  @doc "Whether a template slug belongs to a space pipeline rather than a shared flow."
  def derived_slug?(slug) when is_binary(slug), do: String.match?(slug, ~r/\.space-[0-9a-f]{32}$/)
  def derived_slug?(_slug), do: false

  defp matching_version(template_id, checksum) do
    Version
    |> where(
      [version],
      version.flow_template_id == ^template_id and version.checksum == ^checksum
    )
    |> order_by([version], desc: version.version)
    |> limit(1)
    |> Repo.one()
  end

  defp validate(space, definition, overrides) do
    case Pipeline.apply(definition, overrides, unavailable: unavailable_steps(space)) do
      {:ok, definition} -> {:ok, definition}
      {:error, issues} -> {:error, {:invalid, issues}}
    end
  end

  defp ensure_changed(space, overrides) do
    if current_overrides(space) == overrides, do: {:error, :unchanged}, else: :ok
  end

  defp insert_version(_space, _overrides, _opts, 0), do: {:error, :version_conflict}

  defp insert_version(space, overrides, opts, attempts) do
    next = ((current(space) || %{version: 0}).version || 0) + 1

    attrs = %{
      space_id: space.id,
      created_by_id: user_id(Keyword.get(opts, :user)),
      version: next,
      overrides: overrides,
      note: normalize_note(Keyword.get(opts, :note))
    }

    case %PipelineVersion{} |> PipelineVersion.changeset(attrs) |> Repo.insert() do
      {:ok, version} ->
        {:ok, version}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :space_id) and attempts > 1,
          do: insert_version(space, overrides, opts, attempts - 1),
          else: {:error, changeset}
    end
  end

  defp user_id(%{id: id}) when is_binary(id), do: id
  defp user_id(_user), do: nil

  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 200)
    end
  end

  defp normalize_note(_note), do: nil

  defp base_template(%Space{default_flow_template: template})
       when is_binary(template) and template != "",
       do: template

  defp base_template(%Space{}) do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(:default_template, @default_template)
  end
end
