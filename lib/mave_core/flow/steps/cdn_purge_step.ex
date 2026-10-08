defmodule MaveCore.Flow.Steps.CdnPurgeStep do
  @moduledoc """
  Purges CDN paths after manifest publication.

  Default behavior is safe:
  - without a configured endpoint, step returns `status: "skipped"`
  - with `cdn_purge_strict` enabled, missing endpoint or failed purge returns an error
  """
  @behaviour MaveCore.Flow.Step

  alias MaveCore.Flow.Steps.Support, as: StepSupport
  alias MaveCore.Media.CdnCache
  alias MaveCore.PublicHttpUrl

  @impl true
  def run(step_definition, context) do
    run_input = Map.get(context, :run_input, %{})
    dependency_outputs = Map.get(context, :dependency_outputs, %{})
    dependency_artifacts = Map.get(context, :dependency_artifacts, %{})
    params = Map.get(step_definition, "params", %{})
    step_id = Map.get(step_definition, "id", "purge_cdn")

    strict? = StepSupport.strict_enabled?(params, run_input, "cdn_purge_strict")

    paths = resolve_paths(run_input, params, dependency_outputs, dependency_artifacts)

    space_hash =
      resolve_context_value(
        "space_hash",
        run_input,
        params,
        dependency_outputs,
        dependency_artifacts
      )

    region =
      resolve_context_value("region", run_input, params, dependency_outputs, dependency_artifacts)

    run_purge(step_id, strict?, paths, space_hash, region, run_input, params)
  end

  defp resolve_paths(run_input, params, dependency_outputs, dependency_artifacts) do
    declared_paths =
      normalize_path_list(Map.get(run_input, "cdn_purge_paths")) ++
        normalize_path_list(Map.get(params, "paths"))

    manifest_paths =
      extract_manifest_paths(dependency_outputs) ++ extract_manifest_paths(dependency_artifacts)

    (declared_paths ++ manifest_paths)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp run_purge(step_id, strict?, paths, space_hash, region, run_input, params) do
    if CdnCache.configured?() do
      purge_with_configured_purger(step_id, strict?, paths, space_hash, region)
    else
      purge_with_endpoint(step_id, strict?, paths, run_input, params)
    end
  end

  defp purge_with_configured_purger(step_id, strict?, paths, space_hash, region) do
    with {:ok, paths} <- require_paths(paths),
         {:ok, space_hash} <- require_space_hash(space_hash),
         :ok <- CdnCache.purge(space_hash, region, paths) do
      {:ok,
       %{
         "status" => "ok",
         "step_type" => "cdn.purge",
         "step_id" => step_id,
         "backend" => "configured_purger",
         "space_hash" => space_hash,
         "region" => region,
         "paths" => paths
       }, []}
    else
      {:error, reason} when strict? ->
        {:error, {:cdn_purge_failed, reason}}

      {:error, :missing_paths} ->
        {:ok, skipped_output(step_id, "no paths"), []}

      {:error, :missing_space_hash} ->
        {:ok, skipped_output(step_id, "missing space hash"), []}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason, nil, paths), []}
    end
  end

  defp purge_with_endpoint(step_id, strict?, paths, run_input, params) do
    {endpoint_source, endpoint} = resolve_purge_endpoint(run_input, params)

    headers =
      Map.get(run_input, "cdn_purge_headers") || Map.get(params, "headers") ||
        Application.get_env(:mave_core, :cdn_purge_headers, %{})

    with {:ok, endpoint} <- require_endpoint(endpoint),
         {:ok, paths} <- require_paths(paths),
         {:ok, response_status} <- purge_endpoint(endpoint, endpoint_source, headers, paths) do
      {:ok,
       %{
         "status" => "ok",
         "step_type" => "cdn.purge",
         "step_id" => step_id,
         "endpoint" => endpoint,
         "paths" => paths,
         "response_status" => response_status
       }, []}
    else
      {:error, :missing_endpoint} when strict? ->
        {:error, {:cdn_purge_failed, :missing_endpoint}}

      {:error, :missing_paths} when strict? ->
        {:error, {:cdn_purge_failed, :missing_paths}}

      {:error, reason} when strict? ->
        {:error, {:cdn_purge_failed, reason}}

      {:error, :missing_endpoint} ->
        {:ok, skipped_output(step_id, "missing endpoint"), []}

      {:error, :missing_paths} ->
        {:ok, skipped_output(step_id, "no paths"), []}

      {:error, reason} ->
        {:ok, unavailable_output(step_id, reason, endpoint, paths), []}
    end
  end

  defp resolve_purge_endpoint(run_input, params) do
    cond do
      is_binary(Map.get(run_input, "cdn_purge_endpoint")) ->
        {:run_input, Map.get(run_input, "cdn_purge_endpoint")}

      is_binary(Map.get(params, "endpoint")) ->
        {:params, Map.get(params, "endpoint")}

      true ->
        {:config, Application.get_env(:mave_core, :cdn_purge_endpoint)}
    end
  end

  defp extract_manifest_paths(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {_key, value} -> manifest_paths_from_value(value) end)
  end

  defp extract_manifest_paths(_), do: []

  defp manifest_paths_from_value(%{"manifest_key" => key}) when is_binary(key), do: [key]

  defp manifest_paths_from_value(%{"manifest_uri" => "s3://" <> _ = uri}) do
    case String.split(uri, "/", parts: 4) do
      [_scheme, "", _bucket, key] when is_binary(key) and key != "" -> [key]
      _ -> []
    end
  end

  defp manifest_paths_from_value(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"name" => "manifest", "uri" => "s3://" <> _ = uri} ->
        manifest_paths_from_value(%{"manifest_uri" => uri})

      %{"name" => "manifest", "metadata" => %{"path" => path}} when is_binary(path) ->
        [path]

      _ ->
        []
    end)
  end

  defp manifest_paths_from_value(_), do: []

  defp normalize_path_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_path_list(path) when is_binary(path), do: [path]
  defp normalize_path_list(_), do: []

  defp resolve_context_value(key, run_input, params, dependency_outputs, dependency_artifacts) do
    Map.get(run_input, key) ||
      Map.get(params, key) ||
      extract_context_value(key, dependency_outputs) ||
      extract_context_value(key, dependency_artifacts)
  end

  defp extract_context_value(key, map) when is_map(map) do
    Enum.find_value(map, fn {_entry_key, value} -> context_value_from_value(value, key) end)
  end

  defp extract_context_value(_key, _map), do: nil

  defp context_value_from_value(value, key) when is_map(value) do
    cond do
      is_binary(Map.get(value, key)) ->
        Map.get(value, key)

      is_map(Map.get(value, "metadata")) and is_binary(get_in(value, ["metadata", key])) ->
        get_in(value, ["metadata", key])

      true ->
        nil
    end
  end

  defp context_value_from_value(values, key) when is_list(values) do
    Enum.find_value(values, &context_value_from_value(&1, key))
  end

  defp context_value_from_value(_value, _key), do: nil

  defp purge_endpoint(endpoint, endpoint_source, headers, paths) do
    payload = %{"paths" => paths}
    req_headers = normalize_headers(headers)

    with {:ok, req_options} <- purge_req_options(endpoint, endpoint_source, req_headers, payload) do
      case Req.request(req_options) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, status}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp purge_req_options(endpoint, :config, headers, payload) do
    {:ok, [url: endpoint, method: :post, json: payload, headers: headers]}
  end

  defp purge_req_options(endpoint, _endpoint_source, headers, payload) do
    case PublicHttpUrl.req_options(endpoint,
           method: :post,
           json: payload,
           headers: headers
         ) do
      {:ok, req_options} -> {:ok, req_options}
      {:error, reason} -> {:error, {:unsafe_cdn_purge_endpoint, reason}}
    end
  end

  defp normalize_headers(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      {k, v} -> [{to_string(k), to_string(v)}]
      _ -> []
    end)
  end

  defp normalize_headers(_), do: []

  defp require_endpoint(endpoint) when is_binary(endpoint) and endpoint != "", do: {:ok, endpoint}
  defp require_endpoint(_), do: {:error, :missing_endpoint}

  defp require_paths(paths) when is_list(paths) and paths != [], do: {:ok, paths}
  defp require_paths(_), do: {:error, :missing_paths}

  defp require_space_hash(space_hash) when is_binary(space_hash) and space_hash != "",
    do: {:ok, space_hash}

  defp require_space_hash(_space_hash), do: {:error, :missing_space_hash}

  defp skipped_output(step_id, reason) do
    %{
      "status" => "skipped",
      "step_type" => "cdn.purge",
      "step_id" => step_id,
      "reason" => reason
    }
  end

  defp unavailable_output(step_id, reason, endpoint, paths) do
    %{
      "status" => "unavailable",
      "step_type" => "cdn.purge",
      "step_id" => step_id,
      "endpoint" => endpoint,
      "paths" => paths,
      "error" => inspect(reason)
    }
  end
end
