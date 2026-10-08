defmodule MaveCore.LogRedaction do
  @moduledoc """
  Removes labeled credentials and URL credentials before Logger dispatches events.

  This complements Phoenix parameter filtering. It does not sanitize arbitrary
  response bodies or replace avoiding secrets in diagnostics in the first place.
  """

  @filtered "[FILTERED]"
  @sensitive_key ~r/password|token|secret|authorization|credential|signature|api[_-]?key/i
  @url ~r{https?://[^\s<>"']+}i
  @credential ~r/(\b(?:password|token|secret|authorization|credential|signature|api[_-]?key)\b["']?\s*(?:=>|[:=])\s*)(?:"[^"]*"|'[^']*'|[^\s,}\]]+)/i
  @authorization ~r/\b(Bearer|Basic)\s+[A-Za-z0-9+\/_=.\-]+/i
  @legacy_path ~r{(/(?:api/)?v1/(?:collection/|videos/[^/\s]+/))[^/?\s"']+}
  @upload_topic ~r{\bembed:[^\s"']+}

  def install do
    case :logger.add_primary_filter(:mave_credentials, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, :mave_credentials}} -> :ok
    end
  end

  def filter(%{msg: message} = event, _config) do
    event
    |> Map.put(:msg, redact_message(message))
    |> Map.update(:meta, %{}, &redact/1)
  rescue
    _ ->
      %{event | msg: {:string, "[FILTERED invalid diagnostic]"}}
      |> Map.put(:meta, %{})
  end

  def redact(value) when is_binary(value) do
    value = Regex.replace(@url, value, &redact_url/1)
    value = Regex.replace(@legacy_path, value, "\\1#{@filtered}")
    value = Regex.replace(@upload_topic, value, "embed:#{@filtered}")
    value = Regex.replace(@authorization, value, "\\1 #{@filtered}")
    Regex.replace(@credential, value, "\\1#{@filtered}")
  end

  def redact(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Map.new(fn {key, item} ->
      if sensitive_key?(key), do: {key, @filtered}, else: {key, redact(item)}
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact({key, value}) when is_atom(key) or is_binary(key) do
    if sensitive_key?(key), do: {key, @filtered}, else: {key, redact(value)}
  end

  def redact(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> redact() |> List.to_tuple()

  def redact(value), do: value

  defp redact_message({:string, message}),
    do: {:string, message |> IO.chardata_to_string() |> redact()}

  defp redact_message({:report, report}), do: {:report, redact(report)}

  defp redact_message({format, args}) when is_list(args) do
    {:string, format |> :io_lib.format(args) |> IO.chardata_to_string() |> redact()}
  end

  defp redact_message(message), do: message

  defp redact_url(url) do
    uri = URI.parse(url)

    %{uri | userinfo: nil, query: nil, fragment: nil, authority: nil}
    |> URI.to_string()
    |> then(fn safe -> if safe == url, do: safe, else: safe <> "[FILTERED]" end)
  rescue
    ArgumentError -> @filtered
  end

  defp sensitive_key?(key) when is_atom(key) or is_binary(key),
    do: Regex.match?(@sensitive_key, to_string(key))

  defp sensitive_key?(_key), do: false
end
