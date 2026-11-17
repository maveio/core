defmodule MaveCore.Flow.Pipeline do
  @moduledoc """
  Space-level changes to a flow definition.

  A pipeline is a small set of overrides on top of a flow definition: optional
  steps that are turned off, add-on steps that are turned on, and values for
  the step options a step type marks as editable. Add-on steps are the steps
  that step plugins offer for the flow (`MaveCore.Flow.StepRegistry.offered_steps/1`);
  they are off until a space adds them. Applying the overrides yields a regular flow definition that the
  engine runs like any other, so the editor and the engine share one set of
  dependency rules:

  - Required steps cannot be turned off.
  - Turning a step off also turns off the optional steps that cannot work
    without it, following each step type's dependency policy in
    `MaveCore.Flow.StepRegistry`.
  - A change that would leave a required step without something it needs is
    rejected.

  Overrides are keyed by step id and ignore steps the definition does not have,
  so the same overrides apply to related flows such as the local and
  remote-source variants of a preset.
  """

  alias MaveCore.Flow.{Definition, StepRegistry}

  @type overrides :: %{optional(String.t()) => term()}
  @type issue :: %{code: atom(), step_id: String.t() | nil, message: String.t()}

  @max_text_length 2_000

  @doc "Overrides that change nothing."
  def empty, do: %{"disabled_steps" => [], "added_steps" => [], "settings" => %{}}

  def empty?(overrides) do
    normalize(overrides) == empty()
  end

  @doc """
  Returns overrides in their stored shape: sorted unique step ids and only
  non-empty string-keyed settings. Unknown keys are dropped.
  """
  def normalize(overrides) when is_map(overrides) do
    disabled = normalize_ids(fetch_key(overrides, "disabled_steps"))
    added = normalize_ids(fetch_key(overrides, "added_steps"))

    settings =
      case fetch_key(overrides, "settings") do
        settings when is_map(settings) -> normalize_settings(settings)
        _ -> %{}
      end

    %{"disabled_steps" => disabled, "added_steps" => added, "settings" => settings}
  end

  def normalize(_overrides), do: empty()

  defp normalize_ids(ids) do
    ids
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Turns a step off or back on in the overrides."
  def put_step_enabled(overrides, step_id, enabled?) when is_binary(step_id) do
    overrides = normalize(overrides)

    disabled =
      if enabled?,
        do: List.delete(overrides["disabled_steps"], step_id),
        else: [step_id | overrides["disabled_steps"]]

    normalize(%{overrides | "disabled_steps" => disabled})
  end

  @doc "Adds an add-on step to the pipeline or removes it again."
  def put_step_added(overrides, step_id, added?) when is_binary(step_id) do
    overrides = normalize(overrides)

    added =
      if added?,
        do: [step_id | overrides["added_steps"]],
        else: List.delete(overrides["added_steps"], step_id)

    normalize(%{overrides | "added_steps" => added})
  end

  @doc "Sets one editable option of a step. `nil` and blank text restore the default."
  def put_setting(overrides, step_id, key, value) when is_binary(step_id) and is_binary(key) do
    overrides = normalize(overrides)
    step_settings = overrides["settings"] |> Map.get(step_id, %{}) |> Map.put(key, value)
    normalize(%{overrides | "settings" => Map.put(overrides["settings"], step_id, step_settings)})
  end

  @doc """
  Applies overrides to a definition.

  Returns the definition the engine should run, or the issues that make the
  overrides invalid for this definition. See `resolve/3` for the options.
  """
  @spec apply(map(), overrides(), keyword()) :: {:ok, map()} | {:error, [issue()]}
  def apply(definition, overrides, opts \\ []) do
    case resolve(definition, overrides, opts) do
      %{issues: [], definition: effective} -> {:ok, effective}
      %{issues: issues} -> {:error, issues}
    end
  end

  @doc """
  Describes a definition with overrides applied, for an editor.

  Every step of the definition is returned in order with its state:

  - `:enabled`: runs.
  - `:disabled`: turned off by the overrides.
  - `:auto_disabled`: turned off because of the steps in `disabled_by`.

  `locked` steps are required and cannot be turned off. `addon` steps come
  from a step plugin and are `:disabled` until the overrides add them.
  `definition` is the resulting flow definition, or `nil` when there are
  `issues`.

  Pass `unavailable: %{step_type => reason}` for step types that cannot be
  used here; adding an add-on step of such a type is an issue.
  """
  def resolve(definition, overrides, opts \\ []) do
    overrides = normalize(overrides)
    unavailable = Keyword.get(opts, :unavailable, %{})
    offered = StepRegistry.offered_steps(definition)
    addons = MapSet.new(offered, & &1["id"])
    steps = Definition.steps(definition) ++ offered
    by_id = Map.new(steps, &{&1["id"], &1})
    added = MapSet.new(overrides["added_steps"], & &1) |> MapSet.intersection(addons)

    unavailable_issues =
      for step_id <- Enum.sort(added), reason = unavailable[by_id[step_id]["type"]] do
        issue(
          :step_unavailable,
          step_id,
          "#{step_name(by_id[step_id])} is not available: #{reason}"
        )
      end

    requested =
      overrides["disabled_steps"]
      |> Enum.filter(&(Map.has_key?(by_id, &1) and not MapSet.member?(addons, &1)))
      |> MapSet.new()

    locked_issues =
      for step_id <- Enum.sort(requested), Definition.required?(by_id[step_id]) do
        issue(:required_step, step_id, "#{step_name(by_id[step_id])} is required and stays on.")
      end

    requested =
      requested
      |> MapSet.reject(&Definition.required?(by_id[&1]))
      |> MapSet.union(MapSet.difference(addons, added))

    {disabled, causes, blocked_issues} = cascade(steps, by_id, requested)

    {settings_by_step, setting_issues} = resolve_settings(steps, overrides["settings"])
    issues = locked_issues ++ unavailable_issues ++ blocked_issues ++ setting_issues

    effective = effective_definition(definition, steps, by_id, disabled, settings_by_step)

    issues =
      case issues == [] && Definition.validate(effective) do
        {:error, message} -> [issue(:invalid_definition, nil, message)]
        _ -> issues
      end

    %{
      definition: if(issues == [], do: effective),
      issues: issues,
      overrides: overrides,
      steps:
        steps
        |> describe_steps(requested, disabled, causes, settings_by_step, overrides)
        |> Enum.map(fn step ->
          reason = unavailable[step.type]

          Map.merge(step, %{
            addon: MapSet.member?(addons, step.id),
            available: is_nil(reason),
            unavailable_reason: reason
          })
        end)
    }
  end

  @doc """
  The optional steps that turning `step_id` off would turn off with it, given
  the current overrides.
  """
  def also_disabled(definition, overrides, step_id) do
    current = resolve(definition, overrides)
    before = disabled_ids(current)

    off =
      if Enum.any?(current.steps, &(&1.id == step_id and &1.addon)),
        do: put_step_added(overrides, step_id, false),
        else: put_step_enabled(overrides, step_id, false)

    after_toggle = disabled_ids(resolve(definition, off))

    after_toggle
    |> MapSet.difference(before)
    |> MapSet.delete(step_id)
    |> Enum.sort()
  end

  @doc "A short human summary of what the overrides change in the definition."
  def summary(definition, overrides) do
    resolution = resolve(definition, overrides)
    off = Enum.count(resolution.steps, &(not &1.addon and &1.state != :enabled))
    added = Enum.count(resolution.steps, &(&1.addon and &1.state == :enabled))

    changed =
      resolution.steps
      |> Enum.flat_map(& &1.settings)
      |> Enum.count(& &1.changed)

    %{steps_off: off, steps_added: added, settings_changed: changed}
  end

  defp disabled_ids(resolution) do
    resolution.steps
    |> Enum.filter(&(&1.state != :enabled))
    |> MapSet.new(& &1.id)
  end

  # Repeats until stable: a step that lost a dependency either follows it,
  # carries on without it, or (when required) makes the change invalid.
  defp cascade(steps, by_id, requested) do
    do_cascade(steps, by_id, requested, %{}, [])
  end

  defp do_cascade(steps, by_id, disabled, causes, issues) do
    {disabled, causes, issues, changed?} =
      Enum.reduce(steps, {disabled, causes, issues, false}, &cascade_step(&1, by_id, &2))

    if changed?,
      do: do_cascade(steps, by_id, disabled, causes, issues),
      else: {disabled, causes, issues}
  end

  defp cascade_step(step, by_id, {disabled, causes, issues, changed?} = acc) do
    step_id = step["id"]
    lost = Enum.filter(Definition.dependencies(step), &MapSet.member?(disabled, &1))

    cond do
      MapSet.member?(disabled, step_id) or lost == [] ->
        acc

      not starved?(step, by_id, disabled) ->
        acc

      not Definition.required?(step) ->
        {MapSet.put(disabled, step_id), Map.put(causes, step_id, lost), issues, true}

      Enum.any?(issues, &(&1.step_id == step_id)) ->
        acc

      true ->
        message =
          "#{step_name(step)} is required and needs #{names(lost, by_id)}, which would be turned off."

        {disabled, causes, issues ++ [issue(:required_step_blocked, step_id, message)], changed?}
    end
  end

  defp starved?(step, by_id, disabled) do
    remaining = remaining_dependencies(step, by_id, disabled)

    case StepRegistry.dependency_policy(step["type"]) do
      :all ->
        true

      :any ->
        remaining == []

      :accumulate ->
        Enum.all?(remaining, fn dependency_id -> by_id[dependency_id]["type"] == step["type"] end)
    end
  end

  # Dependencies that are left once disabled steps are removed. A step that
  # accumulates takes over the dependencies of a disabled predecessor of its
  # own type, so the chain keeps its order.
  defp remaining_dependencies(step, by_id, disabled, seen \\ MapSet.new()) do
    accumulates? = StepRegistry.dependency_policy(step["type"]) == :accumulate

    step
    |> Definition.dependencies()
    |> Enum.flat_map(fn dependency_id ->
      dependency = by_id[dependency_id]

      cond do
        not MapSet.member?(disabled, dependency_id) ->
          [dependency_id]

        accumulates? and dependency["type"] == step["type"] and
            not MapSet.member?(seen, dependency_id) ->
          remaining_dependencies(dependency, by_id, disabled, MapSet.put(seen, dependency_id))

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp effective_definition(definition, steps, by_id, disabled, settings_by_step) do
    effective_steps =
      steps
      |> Enum.reject(&MapSet.member?(disabled, &1["id"]))
      |> Enum.map(fn step ->
        step
        |> put_dependencies(remaining_dependencies(step, by_id, disabled))
        |> put_params(Map.get(settings_by_step, step["id"], %{}))
      end)

    Map.put(definition, "steps", effective_steps)
  end

  defp put_dependencies(step, dependencies) do
    cond do
      dependencies == Definition.dependencies(step) -> step
      dependencies == [] -> Map.delete(step, "depends_on")
      true -> Map.put(step, "depends_on", dependencies)
    end
  end

  defp put_params(step, values) when map_size(values) == 0, do: step

  defp put_params(step, values) do
    params =
      Enum.reduce(values, Map.get(step, "params", %{}), fn
        {key, nil}, params -> Map.delete(params, key)
        {key, value}, params -> Map.put(params, key, value)
      end)

    if params == %{}, do: Map.delete(step, "params"), else: Map.put(step, "params", params)
  end

  # Casts the stored settings against each step type's editable options.
  defp resolve_settings(steps, settings) do
    Enum.reduce(steps, {%{}, []}, fn step, {values, issues} ->
      {step_values, step_issues} = resolve_step_settings(step, Map.get(settings, step["id"], %{}))
      values = if step_values == %{}, do: values, else: Map.put(values, step["id"], step_values)
      {values, issues ++ step_issues}
    end)
  end

  defp resolve_step_settings(step, raw_values) do
    options = Map.new(StepRegistry.editable_options(step["type"]), &{&1["key"], &1})

    raw_values
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {key, raw}, {values, issues} ->
      case cast_setting(options[key], raw) do
        {:ok, value} ->
          {Map.put(values, key, value), issues}

        {:error, message} ->
          {values,
           issues ++ [issue(:invalid_setting, step["id"], "#{step_name(step)}: #{message}")]}
      end
    end)
  end

  defp cast_setting(nil, _raw), do: {:error, "this setting cannot be changed."}
  defp cast_setting(_option, nil), do: {:ok, nil}

  defp cast_setting(%{"type" => "text"} = option, raw) when is_binary(raw) do
    value = String.trim(raw)
    max_length = Map.get(option, "max_length", @max_text_length)

    cond do
      value == "" ->
        {:ok, nil}

      String.length(value) > max_length ->
        {:error, "#{label(option)} can be at most #{max_length} characters."}

      true ->
        {:ok, value}
    end
  end

  defp cast_setting(%{"type" => "integer"} = option, raw) do
    case parse_integer(raw) do
      {:ok, value} ->
        min = option["min"]
        max = option["max"]

        cond do
          is_integer(min) and value < min -> {:error, "#{label(option)} must be at least #{min}."}
          is_integer(max) and value > max -> {:error, "#{label(option)} must be at most #{max}."}
          true -> {:ok, value}
        end

      :blank ->
        {:ok, nil}

      :error ->
        {:error, "#{label(option)} must be a whole number."}
    end
  end

  defp cast_setting(%{"type" => "boolean"}, raw) when is_boolean(raw), do: {:ok, raw}

  defp cast_setting(%{"type" => "boolean"}, raw) when raw in ["true", "false"],
    do: {:ok, raw == "true"}

  defp cast_setting(%{"type" => "select"} = option, raw) when is_binary(raw) do
    values = Enum.map(Map.get(option, "choices", []), & &1["value"])

    cond do
      raw == "" -> {:ok, nil}
      raw in values -> {:ok, raw}
      true -> {:error, "#{label(option)} has an unknown value."}
    end
  end

  defp cast_setting(option, _raw), do: {:error, "#{label(option)} has an invalid value."}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        :blank

      trimmed ->
        case Integer.parse(trimmed) do
          {parsed, ""} -> {:ok, parsed}
          _ -> :error
        end
    end
  end

  defp parse_integer(_value), do: :error

  defp describe_steps(steps, requested, disabled, causes, settings_by_step, overrides) do
    dependents =
      Enum.reduce(steps, %{}, fn step, acc ->
        Enum.reduce(Definition.dependencies(step), acc, fn dependency_id, acc ->
          Map.update(acc, dependency_id, [step["id"]], &(&1 ++ [step["id"]]))
        end)
      end)

    Enum.map(steps, fn step ->
      step_id = step["id"]
      type = StepRegistry.fetch(step["type"]) || %{}

      state =
        cond do
          MapSet.member?(requested, step_id) -> :disabled
          MapSet.member?(disabled, step_id) -> :auto_disabled
          true -> :enabled
        end

      %{
        id: step_id,
        type: step["type"],
        name: step_name(step),
        type_name: Map.get(type, :name, step["type"]),
        description: Map.get(type, :description),
        stage: Map.get(type, :stage, "ingest"),
        params: Map.get(step, "params", %{}),
        lane: Map.get(step, "lane", "normal"),
        state: state,
        locked: Definition.required?(step),
        disabled_by: Map.get(causes, step_id, []),
        dependencies: Definition.dependencies(step),
        dependents: Map.get(dependents, step_id, []),
        settings:
          describe_settings(
            step,
            Map.get(settings_by_step, step_id, %{}),
            get_in(overrides, ["settings", step_id]) || %{}
          )
      }
    end)
  end

  defp describe_settings(step, values, raw_values) do
    params = Map.get(step, "params", %{})

    Enum.map(StepRegistry.editable_options(step["type"]), fn option ->
      key = option["key"]
      base = Map.get(params, key, option["default"])
      changed? = Map.has_key?(values, key) and values[key] != nil and values[key] != base

      %{
        key: key,
        type: option["type"],
        label: label(option),
        description: option["description"],
        placeholder: option["placeholder"],
        min: option["min"],
        max: option["max"],
        max_length: option["max_length"],
        choices: Map.get(option, "choices", []),
        base: base,
        value: if(changed?, do: values[key], else: base),
        input: Map.get(raw_values, key, base),
        changed: changed?
      }
    end)
  end

  defp normalize_settings(settings) do
    settings
    |> Enum.flat_map(fn
      {step_id, values} when is_map(values) -> normalize_step_settings(step_id, values)
      _ -> []
    end)
    |> Map.new()
  end

  defp normalize_step_settings(step_id, values) do
    values =
      for {key, value} <- values, not blank?(value), into: %{}, do: {to_string(key), value}

    if values == %{}, do: [], else: [{to_string(step_id), values}]
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp fetch_key(map, "disabled_steps"),
    do: Map.get(map, "disabled_steps") || Map.get(map, :disabled_steps)

  defp fetch_key(map, "added_steps"),
    do: Map.get(map, "added_steps") || Map.get(map, :added_steps)

  defp fetch_key(map, "settings"), do: Map.get(map, "settings") || Map.get(map, :settings)

  defp names(step_ids, by_id), do: Enum.map_join(step_ids, ", ", &step_name(by_id[&1]))

  defp step_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp step_name(%{"id" => id}), do: id

  defp label(%{"label" => label}) when is_binary(label), do: label
  defp label(%{"key" => key}), do: key

  defp issue(code, step_id, message), do: %{code: code, step_id: step_id, message: message}
end
