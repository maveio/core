defmodule MaveCore.Flow.StepPlugin do
  @moduledoc """
  Contract for encoding steps that are added to Mave without changing Core.

  A plugin is a module that describes its own step type and runs it. Register
  it with:

      config :mave_core, :flow_step_plugins, [MyApp.Steps.Watermark]

  The step type then validates in flow definitions, runs in the engine, is
  listed by `GET /v1/flow/step-types` and appears in the encoding editor like a
  built-in step.

  ## The contract

  `c:contract/0` returns a map with:

  - `:type` (required): unique type such as `"quality.vmaf"`. Built-in types
    cannot be replaced.
  - `:name`, `:description` (required): what people see in the editor.
  - `:stage` (required): where the step sits between upload and delivery. Use
    a built-in stage (see `MaveCore.Flow.StepRegistry.stages/0`) or a new one.
  - `:executor`: `:inline` (default) or `:flame` for heavy work such as FFmpeg.
  - `:dependencies`: `:all` (default), `:any` or `:accumulate`; what happens to
    the step when a step it depends on is turned off.
  - `:inputs`: what the step connects to. Each input has a `"key"`, a
    `"label"` and the step types it `"accepts"`.
  - `:outputs`: what the step produces for later steps, each with a `"key"`
    and `"label"`.
  - `:options`: settings, in the format of the built-in step options. Options
    with `"editable" => true` can be changed per space in the editor.
  - `:progress`: `%{"label" => "measuring"}` names the work while the step
    reports progress through `context[:progress_reporter]`.
  - `:results`: values from the step output to show once it ran. Each result
    has a `"key"` (a dotted path into the output), a `"label"` and optionally
    `"format"` (`"number"`, `"integer"`, `"text"` or `"boolean"`),
    `"decimals"`, `"unit"` and `"primary" => true` for the value shown next to
    the step.

  ## Execution

  A plugin also implements `MaveCore.Flow.Step`: `run/2` receives the step
  definition and the execution context and returns `{:ok, output, artifacts}`
  or `{:error, reason}`.

  ## Optional callbacks

  - `c:placements/1` offers steps of this type for a flow. The editor lists
    them as add-ons that are off until a space turns them on.
  - `c:availability/0` reports whether this installation can run the step, for
    example whether a required FFmpeg filter is present.

  Whether a customer may use a step is a host decision; see
  `MaveCore.UsageLimits.can_use_encoding_step?/2`.
  """

  @type contract :: %{
          required(:type) => String.t(),
          required(:name) => String.t(),
          required(:description) => String.t(),
          required(:stage) => String.t(),
          optional(:category) => String.t(),
          optional(:executor) => :inline | :flame,
          optional(:dependencies) => :all | :any | :accumulate,
          optional(:inputs) => [map()],
          optional(:outputs) => [map()],
          optional(:options) => [map()],
          optional(:progress) => map(),
          optional(:results) => [map()]
        }

  @callback contract() :: contract()

  @doc """
  Steps of this type that fit the given flow definition. Each step needs an
  `"id"` and may set `"name"`, `"depends_on"`, `"params"` and `"lane"`.
  """
  @callback placements(definition :: map()) :: [map()]

  @callback availability() :: :ok | {:unavailable, String.t()}

  @optional_callbacks placements: 1, availability: 0

  @type_format ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/
  @stage_format ~r/^[a-z][a-z0-9_]*$/
  @executors [:inline, :flame]
  @dependency_policies [:all, :any, :accumulate]
  @option_types ~w(text integer boolean select)
  @result_formats ~w(number integer text boolean)

  @doc """
  Checks a plugin module and returns its contract with defaults filled in, or
  the reasons it cannot be registered.
  """
  @spec validate(module()) :: {:ok, contract()} | {:error, [String.t()]}
  def validate(module) when is_atom(module) do
    with :ok <- ensure_plugin(module),
         {:ok, contract} <- fetch_contract(module) do
      case contract_errors(contract) do
        [] -> {:ok, with_defaults(contract)}
        errors -> {:error, errors}
      end
    end
  end

  def validate(_module), do: {:error, ["a plugin must be a module"]}

  defp ensure_plugin(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, ["module is not available"]}

      not function_exported?(module, :contract, 0) ->
        {:error, ["contract/0 is not defined"]}

      not function_exported?(module, :run, 2) ->
        {:error, ["run/2 is not defined"]}

      true ->
        :ok
    end
  end

  defp fetch_contract(module) do
    case module.contract() do
      contract when is_map(contract) -> {:ok, contract}
      _other -> {:error, ["contract/0 must return a map"]}
    end
  end

  defp contract_errors(contract) do
    Enum.reject(
      [
        format_error(contract, :type, @type_format, "must look like \"category.name\""),
        text_error(contract, :name),
        text_error(contract, :description),
        format_error(
          contract,
          :stage,
          @stage_format,
          "must be lowercase letters and underscores"
        ),
        member_error(contract, :executor, @executors),
        member_error(contract, :dependencies, @dependency_policies),
        entries_error(contract, :inputs, &valid_connection?/1),
        entries_error(contract, :outputs, &valid_connection?/1),
        entries_error(contract, :options, &valid_option?/1),
        entries_error(contract, :results, &valid_result?/1),
        progress_error(contract)
      ],
      &is_nil/1
    )
  end

  defp format_error(contract, key, format, hint) do
    case Map.get(contract, key) do
      value when is_binary(value) ->
        if Regex.match?(format, value), do: nil, else: "#{key} #{hint}"

      _ ->
        "#{key} is required"
    end
  end

  defp text_error(contract, key) do
    case Map.get(contract, key) do
      value when is_binary(value) and value != "" -> nil
      _ -> "#{key} is required"
    end
  end

  defp member_error(contract, key, allowed) do
    case Map.fetch(contract, key) do
      :error ->
        nil

      {:ok, value} ->
        if value in allowed,
          do: nil,
          else: "#{key} must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}"
    end
  end

  defp entries_error(contract, key, valid?) do
    case Map.get(contract, key, []) do
      entries when is_list(entries) ->
        if Enum.all?(entries, valid?), do: nil, else: "#{key} has an invalid entry"

      _ ->
        "#{key} must be a list"
    end
  end

  defp progress_error(contract) do
    case Map.get(contract, :progress, %{}) do
      %{} = progress ->
        if Map.get(progress, "label", "") |> is_binary(),
          do: nil,
          else: "progress label must be text"

      _ ->
        "progress must be a map"
    end
  end

  defp valid_connection?(%{"key" => key, "label" => label} = connection)
       when is_binary(key) and key != "" and is_binary(label) and label != "" do
    case Map.get(connection, "accepts", []) do
      accepts when is_list(accepts) -> Enum.all?(accepts, &is_binary/1)
      _ -> false
    end
  end

  defp valid_connection?(_connection), do: false

  defp valid_option?(%{"key" => key, "type" => type}) when is_binary(key) and key != "",
    do: type in @option_types

  defp valid_option?(_option), do: false

  defp valid_result?(%{"key" => key, "label" => label} = result)
       when is_binary(key) and key != "" and is_binary(label) and label != "",
       do: Map.get(result, "format", "text") in @result_formats

  defp valid_result?(_result), do: false

  defp with_defaults(contract) do
    contract
    |> Map.put_new(:category, contract.type |> String.split(".") |> hd())
    |> Map.put_new(:executor, :inline)
    |> Map.put_new(:dependencies, :all)
    |> Map.put_new(:inputs, [])
    |> Map.put_new(:outputs, [])
    |> Map.put_new(:options, [])
    |> Map.put_new(:progress, %{})
    |> Map.put_new(:results, [])
  end
end
