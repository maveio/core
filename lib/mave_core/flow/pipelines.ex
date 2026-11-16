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
  alias MaveCore.Flow.{Pipeline, PipelineVersion, Presets, Template, Version}
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
         {:ok, _definition} <- validate(base.definition, overrides),
         :ok <- ensure_changed(space, overrides) do
      insert_version(space, overrides, opts, @save_attempts)
    end
  end

  @doc """
  Chooses the flow template and version a run should use.

  Runs started with `space_pipeline: %Space{}` get the space's overrides applied
  to the selected version. Runs without the option, with a pinned `:version`, or
  for a space without overrides use the selected version unchanged. Overrides
  that no longer fit the flow are skipped rather than failing the upload.
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

  defp validate(definition, overrides) do
    case Pipeline.apply(definition, overrides) do
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
