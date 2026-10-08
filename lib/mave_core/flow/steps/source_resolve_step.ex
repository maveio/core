defmodule MaveCore.Flow.Steps.SourceResolveStep do
  @moduledoc """
  Resolves an input source URL from flow input.
  """
  @behaviour MaveCore.Flow.Step

  @impl true
  def run(_step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    source_url = resolve_source_url(run_input)

    if source_url do
      {:ok,
       %{
         "source_url" => source_url,
         "source_bucket" => Map.get(run_input, "source_bucket"),
         "source_key" => Map.get(run_input, "source_key"),
         "source_region" => Map.get(run_input, "source_region"),
         "source_content_type" => Map.get(run_input, "source_content_type"),
         "upload_key" => Map.get(run_input, "upload_key"),
         "space_hash" => Map.get(run_input, "space_hash"),
         "embed_hash" => Map.get(run_input, "embed_hash"),
         "version" => Map.get(run_input, "version", 0)
       }, []}
    else
      {:error, :missing_source}
    end
  end

  defp resolve_source_url(input) do
    cond do
      is_binary(Map.get(input, "input_url")) and Map.get(input, "input_url") != "" ->
        Map.get(input, "input_url")

      is_binary(Map.get(input, "source_url")) and Map.get(input, "source_url") != "" ->
        Map.get(input, "source_url")

      true ->
        nil
    end
  end
end
