defmodule MaveCore.Flow.Definition do
  @moduledoc """
  Validation and traversal helpers for flow version definitions.
  """

  alias MaveCore.Flow.StepRegistry
  @lane_priorities %{"fast" => 0, "normal" => 50, "background" => 100}

  @spec validate(map() | nil) :: :ok | {:error, String.t()}
  def validate(nil), do: {:error, "definition is required"}
  def validate(definition) when not is_map(definition), do: {:error, "definition must be a map"}

  def validate(definition) do
    with {:ok, steps} <- validate_steps(definition),
         :ok <- validate_unique_ids(steps),
         :ok <- validate_dependencies(steps) do
      validate_acyclic(steps)
    end
  end

  def steps(definition) when is_map(definition) do
    case Map.get(definition, "steps") do
      steps when is_list(steps) -> steps
      _ -> []
    end
  end

  def step_by_id(definition, step_id) when is_binary(step_id) do
    Enum.find(steps(definition), fn step -> Map.get(step, "id") == step_id end)
  end

  def dependencies(step_definition) when is_map(step_definition) do
    case Map.get(step_definition, "depends_on", []) do
      deps when is_list(deps) -> Enum.filter(deps, &is_binary/1)
      _ -> []
    end
  end

  def required?(step_definition) when is_map(step_definition) do
    Map.get(step_definition, "required", true) != false
  end

  def required?(_), do: true

  def terminal_step_status?(status) when is_binary(status) do
    status in ~w(succeeded failed cancelled skipped)
  end

  def terminal_step_status?(_), do: false

  def ready_steps(definition, step_runs_by_id) when is_map(step_runs_by_id) do
    steps(definition)
    |> Enum.filter(fn step ->
      step_id = Map.get(step, "id")

      case Map.get(step_runs_by_id, step_id) do
        %{status: "queued"} ->
          Enum.all?(dependencies(step), &dependency_satisfied?(definition, step_runs_by_id, &1))

        _ ->
          false
      end
    end)
    |> Enum.sort_by(fn step ->
      {step_priority(step), Map.get(step, "id", "")}
    end)
  end

  def next_ready_steps(definition, step_runs_by_id) when is_map(step_runs_by_id) do
    case ready_steps(definition, step_runs_by_id) do
      [] ->
        []

      [first | _] = steps ->
        highest_priority = step_priority(first)
        Enum.take_while(steps, &(step_priority(&1) == highest_priority))
    end
  end

  def blocked_steps(definition, step_runs_by_id) when is_map(step_runs_by_id) do
    steps(definition)
    |> Enum.filter(fn step ->
      step_id = Map.get(step, "id")

      match?(%{status: "queued"}, Map.get(step_runs_by_id, step_id)) and
        permanently_blocked?(definition, step_runs_by_id, step)
    end)
  end

  def step_priority(step_definition) when is_map(step_definition) do
    case Map.get(step_definition, "priority") do
      priority when is_integer(priority) and priority >= 0 ->
        priority

      nil ->
        step_definition
        |> Map.get("lane")
        |> lane_priority()

      _ ->
        lane_priority(nil)
    end
  end

  def step_priority(_), do: lane_priority(nil)

  defp validate_steps(definition) do
    case Map.get(definition, "steps") do
      steps when is_list(steps) and steps != [] ->
        Enum.reduce_while(steps, :ok, fn step, :ok ->
          step
          |> validate_steps_entry()
          |> step_validation_result()
        end)
        |> normalize_validate_steps_result(steps)

      _ ->
        {:error, "definition.steps must be a non-empty list"}
    end
  end

  defp validate_steps_entry(step) when is_map(step), do: validate_step(step)
  defp validate_steps_entry(_step), do: {:error, "every step must be an object"}

  defp step_validation_result(:ok), do: {:cont, :ok}
  defp step_validation_result({:error, message}), do: {:halt, {:error, message}}

  defp normalize_validate_steps_result(:ok, steps), do: {:ok, steps}
  defp normalize_validate_steps_result({:error, message}, _steps), do: {:error, message}

  defp validate_step(step) do
    required = ["id", "type", "name"]

    missing =
      Enum.filter(required, fn field ->
        value = Map.get(step, field)
        not (is_binary(value) and value != "")
      end)

    cond do
      missing != [] ->
        {:error, "step is missing required fields: #{Enum.join(missing, ", ")}"}

      not StepRegistry.known_type?(Map.get(step, "type")) ->
        {:error, "unknown step type: #{Map.get(step, "type")}"}

      not valid_depends_on?(step) ->
        {:error, "step #{Map.get(step, "id")} has invalid depends_on"}

      not valid_priority?(step) ->
        {:error, "step #{Map.get(step, "id")} has invalid priority"}

      not valid_lane?(step) ->
        {:error, "step #{Map.get(step, "id")} has invalid lane"}

      not valid_required?(step) ->
        {:error, "step #{Map.get(step, "id")} has invalid required flag"}

      true ->
        :ok
    end
  end

  defp valid_depends_on?(step) do
    case Map.get(step, "depends_on", []) do
      deps when is_list(deps) -> Enum.all?(deps, fn dep -> is_binary(dep) and dep != "" end)
      _ -> false
    end
  end

  defp valid_priority?(step) do
    case Map.get(step, "priority") do
      nil -> true
      priority when is_integer(priority) and priority >= 0 -> true
      _ -> false
    end
  end

  defp valid_lane?(step) do
    case Map.get(step, "lane") do
      nil -> true
      lane when is_binary(lane) -> Map.has_key?(@lane_priorities, lane)
      _ -> false
    end
  end

  defp valid_required?(step) do
    case Map.get(step, "required") do
      nil -> true
      required when is_boolean(required) -> true
      _ -> false
    end
  end

  defp dependency_satisfied?(definition, step_runs_by_id, dependency_id) do
    case Map.get(step_runs_by_id, dependency_id) do
      %{status: "succeeded"} ->
        true

      %{status: status} ->
        optional_dependency?(definition, dependency_id) and terminal_step_status?(status)

      _ ->
        false
    end
  end

  defp permanently_blocked?(definition, step_runs_by_id, step_definition) do
    Enum.any?(dependencies(step_definition), fn dependency_id ->
      case Map.get(step_runs_by_id, dependency_id) do
        %{status: status} ->
          terminal_step_status?(status) and
            not dependency_satisfied?(
              definition,
              step_runs_by_id,
              dependency_id
            )

        _ ->
          false
      end
    end)
  end

  defp optional_dependency?(definition, dependency_id) do
    definition
    |> step_by_id(dependency_id)
    |> required?()
    |> Kernel.not()
  end

  defp lane_priority(lane) when is_binary(lane) do
    Map.get(@lane_priorities, lane, lane_priority(nil))
  end

  defp lane_priority(_), do: Map.fetch!(@lane_priorities, "normal")

  defp validate_unique_ids(steps) do
    ids = Enum.map(steps, &Map.get(&1, "id"))
    unique_ids = MapSet.new(ids)

    if MapSet.size(unique_ids) == length(ids) do
      :ok
    else
      {:error, "step ids must be unique"}
    end
  end

  defp validate_dependencies(steps) do
    ids = MapSet.new(Enum.map(steps, &Map.get(&1, "id")))

    missing_dep =
      steps
      |> Enum.flat_map(&dependencies/1)
      |> Enum.find(fn dep_id -> not MapSet.member?(ids, dep_id) end)

    if missing_dep do
      {:error, "unknown dependency step id: #{missing_dep}"}
    else
      :ok
    end
  end

  defp validate_acyclic(steps) do
    step_ids = Enum.map(steps, &Map.get(&1, "id"))

    indegree =
      Enum.reduce(steps, %{}, fn step, acc ->
        Map.put(acc, Map.get(step, "id"), length(dependencies(step)))
      end)

    adjacency =
      Enum.reduce(steps, %{}, fn step, acc ->
        step_id = Map.get(step, "id")

        Enum.reduce(dependencies(step), acc, fn dependency_id, inner_acc ->
          Map.update(inner_acc, dependency_id, [step_id], fn list -> [step_id | list] end)
        end)
      end)

    queue =
      indegree
      |> Enum.filter(fn {_id, count} -> count == 0 end)
      |> Enum.map(fn {id, _count} -> id end)

    visited_count = process_topology(queue, indegree, adjacency, 0)

    if visited_count == length(step_ids) do
      :ok
    else
      {:error, "definition contains dependency cycle"}
    end
  end

  defp process_topology([], _indegree, _adjacency, visited_count), do: visited_count

  defp process_topology([current | rest], indegree, adjacency, visited_count) do
    {updated_indegree, newly_zero} =
      adjacency
      |> Map.get(current, [])
      |> Enum.reduce({indegree, []}, fn node, {acc_indegree, acc_newly_zero} ->
        new_value = Map.fetch!(acc_indegree, node) - 1
        next_indegree = Map.put(acc_indegree, node, new_value)

        if new_value == 0 do
          {next_indegree, [node | acc_newly_zero]}
        else
          {next_indegree, acc_newly_zero}
        end
      end)

    process_topology(rest ++ newly_zero, updated_indegree, adjacency, visited_count + 1)
  end
end
