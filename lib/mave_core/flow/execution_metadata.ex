defmodule MaveCore.Flow.ExecutionMetadata do
  @moduledoc false

  @runtime_env ~w(POD_NAME POD_NAMESPACE POD_IP NODE_NAME MAVE_RUNTIME_ROLE)

  def current(executor, extra \\ []) do
    runtime =
      @runtime_env
      |> Enum.reduce(%{}, fn name, acc ->
        put_env_value(acc, env_key(name), System.get_env(name))
      end)
      |> put_env_value("hardware_profile", System.get_env("MAVE_HARDWARE_PROFILE"))
      |> put_env_value("hostname", System.get_env("HOSTNAME"))
      |> put_env_value("release_node", node_name())
      |> put_env_value("architecture", system_architecture())
      |> Map.put("schedulers_online", System.schedulers_online())
      |> Map.put("flame_worker", flame_worker?())

    %{}
    |> Map.put("executor", normalize_executor(executor))
    |> Map.put("runtime", runtime)
    |> merge_extra(extra)
  end

  defp merge_extra(metadata, extra) when is_list(extra) do
    Enum.reduce(extra, metadata, fn {key, value}, acc ->
      put_env_value(acc, to_string(key), normalize_value(value))
    end)
  end

  defp merge_extra(metadata, _extra), do: metadata

  defp put_env_value(map, _key, nil), do: map
  defp put_env_value(map, _key, ""), do: map
  defp put_env_value(map, key, value), do: Map.put(map, key, value)

  defp env_key(name) do
    name
    |> String.downcase()
  end

  defp normalize_executor(executor) when is_atom(executor), do: Atom.to_string(executor)
  defp normalize_executor(executor) when is_binary(executor), do: executor
  defp normalize_executor(_executor), do: "unknown"

  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp node_name do
    Node.self()
    |> Atom.to_string()
    |> case do
      "nonode@nohost" -> nil
      value -> value
    end
  end

  defp system_architecture do
    case :erlang.system_info(:system_architecture) do
      value when is_list(value) -> List.to_string(value)
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp flame_worker?, do: is_binary(System.get_env("FLAME_PARENT"))
end
