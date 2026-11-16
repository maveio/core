defmodule MaveCore.Flow.PipelineAssistant do
  @moduledoc """
  Turns a request in plain language into a proposed change to a space's
  encoding pipeline.

  A language model reads the request together with the steps of the pipeline
  and suggests operations: turn a step off or on, or set one of its editable
  settings. Each operation is then applied with `MaveCore.Flow.Pipeline`, the
  code the editor itself uses, so a proposal follows the same dependency and
  validation rules as a manual edit. An operation the editor would refuse is
  left out and reported in `rejected`.

  What a proposal changes is read from the pipeline before and after, not from
  what the model says it did. Nothing is saved here: the caller shows the
  proposal, and a person saves it as a new version with
  `MaveCore.Flow.Pipelines.save/3`.

  The model is reached through a `MaveCore.Flow.PipelineAssistant.Provider`:

      config :mave_core, :pipeline_assistant_provider, MyApp.PipelineModel

  The default is `MaveCore.Flow.PipelineAssistant.Mistral`.
  """

  alias MaveCore.Flow.{Pipeline, Pipelines}
  alias MaveCore.Flow.PipelineAssistant.Mistral
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  @max_request_length 1_000
  @max_reply_length 1_200
  @max_operations 60
  @max_history 8

  @type change :: %{
          kind: :off | :on | :added | :removed | :setting | :follows,
          step_id: String.t(),
          step_name: String.t(),
          text: String.t()
        }

  @type proposal :: %{
          reply: String.t(),
          overrides: Pipeline.overrides(),
          changes: [change()],
          rejected: [%{operation: map(), reason: String.t()}]
        }

  @doc """
  Whether the assistant can be used for a space: the space may edit its
  pipeline, the host allows the assistant and a language model is configured.
  """
  @spec access(Space.t()) :: :ok | {:error, term()}
  def access(%Space{} = space) do
    with :ok <- Pipelines.can_edit?(space),
         :ok <- UsageLimits.can_use_pipeline_assistant?(space) do
      if provider().available?(), do: :ok, else: {:error, :not_configured}
    end
  end

  @doc """
  Asks for a change to `overrides` of `definition`.

  Options:

  - `:unavailable`: step types that cannot be used, as for `Pipeline.resolve/3`.
  - `:history`: earlier turns as `%{role: :user | :assistant, text: text}`.
  - `:usage_context`: passed to the provider for usage recording.
  """
  @spec propose(map(), Pipeline.overrides(), String.t(), keyword()) ::
          {:ok, proposal()} | {:error, term()}
  def propose(definition, overrides, message, opts \\ []) when is_binary(message) do
    message = String.trim(message)
    unavailable = Keyword.get(opts, :unavailable, %{})

    cond do
      message == "" ->
        {:error, :empty_request}

      String.length(message) > @max_request_length ->
        {:error, :request_too_long}

      true ->
        current = Pipeline.resolve(definition, overrides, unavailable: unavailable)

        request = %{
          message: message,
          steps: catalog(current),
          history: opts |> Keyword.get(:history, []) |> Enum.take(-@max_history)
        }

        with {:ok, suggestion} <- provider().suggest(request, opts) do
          {:ok, build_proposal(definition, current, suggestion, unavailable)}
        end
    end
  end

  @doc "The steps of a resolved pipeline as the language model sees them."
  def catalog(resolution) do
    Enum.map(resolution.steps, fn step ->
      reject_blank(%{
        "id" => step.id,
        "name" => step.name,
        "kind" => step.type_name,
        "stage" => step.stage,
        "description" => step.description,
        "state" => catalog_state(step.state),
        "required" => step.locked,
        "add_on" => step.addon,
        "unavailable" => step.unavailable_reason,
        "needs" => step.dependencies,
        "settings" => Enum.map(step.settings, &catalog_setting/1)
      })
    end)
  end

  defp catalog_state(:enabled), do: "on"
  defp catalog_state(:disabled), do: "off"
  defp catalog_state(:auto_disabled), do: "off, because a step it needs is off"

  defp catalog_setting(setting) do
    reject_blank(%{
      "key" => setting.key,
      "label" => setting.label,
      "type" => setting.type,
      "description" => setting.description,
      "value" => setting.value,
      "default" => setting.base,
      "min" => setting.min,
      "max" => setting.max,
      "choices" => Enum.map(setting.choices, & &1["value"])
    })
  end

  defp reject_blank(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", [], false] end)
  end

  defp build_proposal(definition, current, suggestion, unavailable) do
    operations =
      suggestion
      |> Map.get(:operations, [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_operations)

    {overrides, rejected} =
      Enum.reduce(operations, {current.overrides, []}, fn operation, {overrides, rejected} ->
        case apply_operation(definition, overrides, operation, unavailable) do
          {:ok, overrides} -> {overrides, rejected}
          {:error, reason} -> {overrides, rejected ++ [%{operation: operation, reason: reason}]}
        end
      end)

    proposed = Pipeline.resolve(definition, overrides, unavailable: unavailable)

    %{
      reply:
        suggestion |> Map.get(:reply, "") |> to_string() |> String.slice(0, @max_reply_length),
      overrides: proposed.overrides,
      changes: changes(current, proposed),
      rejected: rejected
    }
  end

  # One suggested operation, checked the way the editor checks a manual edit.
  defp apply_operation(definition, overrides, operation, unavailable) do
    resolution = Pipeline.resolve(definition, overrides, unavailable: unavailable)
    step_id = operation |> Map.get("step_id") |> to_string()

    case Enum.find(resolution.steps, &(&1.id == step_id)) do
      nil ->
        {:error, "There is no step \"#{String.slice(step_id, 0, 60)}\" in this pipeline."}

      step ->
        with {:ok, changed} <- change_overrides(overrides, step, operation) do
          accept(definition, resolution, changed, unavailable)
        end
    end
  end

  defp change_overrides(overrides, step, %{"action" => "turn_off"}) do
    cond do
      step.locked -> {:error, "#{step.name} is required and stays on."}
      step.state != :enabled -> {:ok, overrides}
      step.addon -> {:ok, Pipeline.put_step_added(overrides, step.id, false)}
      true -> {:ok, Pipeline.put_step_enabled(overrides, step.id, false)}
    end
  end

  defp change_overrides(overrides, step, %{"action" => "turn_on"}) do
    cond do
      step.state == :enabled ->
        {:ok, overrides}

      step.state == :auto_disabled ->
        {:error, "#{step.name} is off because a step it needs is off."}

      not step.available ->
        {:error, "#{step.name} is not available: #{step.unavailable_reason}"}

      step.addon ->
        {:ok, Pipeline.put_step_added(overrides, step.id, true)}

      true ->
        {:ok, Pipeline.put_step_enabled(overrides, step.id, true)}
    end
  end

  defp change_overrides(overrides, step, %{"action" => "set_setting"} = operation) do
    key = operation |> Map.get("setting") |> to_string()

    case Enum.find(step.settings, &(&1.key == key)) do
      nil ->
        {:error, "#{step.name} has no setting \"#{String.slice(key, 0, 60)}\" to change."}

      setting ->
        case setting_value(setting, Map.get(operation, "value")) do
          {:ok, value} -> {:ok, Pipeline.put_setting(overrides, step.id, key, value)}
          :error -> {:error, "#{step.name}: #{setting.label} has an invalid value."}
        end
    end
  end

  defp change_overrides(_overrides, _step, _operation),
    do: {:error, "This is not a change the pipeline supports."}

  # The flow's own value is stored as "no override", as in the editor.
  defp setting_value(_setting, nil), do: {:ok, nil}

  defp setting_value(setting, value) when is_binary(value) do
    if to_string(setting.base || "") == String.trim(value), do: {:ok, nil}, else: {:ok, value}
  end

  defp setting_value(setting, value) when is_integer(value) or is_boolean(value),
    do: setting_value(setting, to_string(value))

  defp setting_value(_setting, _value), do: :error

  defp accept(definition, resolution, overrides, unavailable) do
    changed = Pipeline.resolve(definition, overrides, unavailable: unavailable)

    case changed.issues -- resolution.issues do
      [] -> {:ok, changed.overrides}
      [issue | _] -> {:error, issue.message}
    end
  end

  # What the proposal changes, read from the pipeline before and after.
  defp changes(current, proposed) do
    previous = Map.new(current.steps, &{&1.id, &1})
    names = Map.new(proposed.steps, &{&1.id, &1.name})

    changes =
      Enum.flat_map(proposed.steps, fn step ->
        case previous[step.id] do
          nil -> []
          old -> state_change(old, step, names) ++ setting_changes(old, step)
        end
      end)

    {follows, direct} = Enum.split_with(changes, &(&1.kind == :follows))
    direct ++ follows
  end

  defp state_change(old, step, names) do
    case {old.state == :enabled, step.state} do
      {true, :enabled} ->
        []

      {false, :enabled} when old.state == :auto_disabled ->
        [change(:follows, step, "#{step.name} turns back on with it")]

      {false, :enabled} when step.addon ->
        [change(:added, step, "Add #{step.name}")]

      {false, :enabled} ->
        [change(:on, step, "Turn on #{step.name}")]

      {true, :disabled} when step.addon ->
        [change(:removed, step, "Remove #{step.name}")]

      {true, :disabled} ->
        [change(:off, step, "Turn off #{step.name}")]

      {true, :auto_disabled} ->
        needs = Enum.map_join(step.disabled_by, ", ", &Map.get(names, &1, &1))
        [change(:follows, step, "#{step.name} turns off too, because it needs #{needs}")]

      {false, _still_off} ->
        []
    end
  end

  defp setting_changes(old, step) do
    previous = Map.new(old.settings, &{&1.key, &1.value})

    for setting <- step.settings,
        Map.has_key?(previous, setting.key),
        previous[setting.key] != setting.value do
      text =
        if setting.changed,
          do: "Set #{setting.label} of #{step.name} to \"#{setting.value}\"",
          else: "Restore #{setting.label} of #{step.name} to its default"

      change(:setting, step, text)
    end
  end

  defp change(kind, step, text),
    do: %{kind: kind, step_id: step.id, step_name: step.name, text: text}

  defp provider, do: Application.get_env(:mave_core, :pipeline_assistant_provider, Mistral)
end
