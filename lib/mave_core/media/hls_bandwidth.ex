defmodule MaveCore.Media.HlsBandwidth do
  @moduledoc false

  # Use packaged bytes, including container overhead, rather than encoder targets.
  def measure(playlist, files) when is_binary(playlist) and is_list(files) do
    sizes = Map.new(files, &{&1["name"], &1["file_size"]})

    with [_, target] <- Regex.run(~r/^#EXT-X-TARGETDURATION:(\d+)\s*$/m, playlist),
         target when target > 0 <- String.to_integer(target),
         segments when segments != [] <- segments(playlist, sizes),
         true <- length(segments) == length(Regex.scan(~r/^#EXTINF:/m, playlist)),
         true <- Enum.all?(segments, &valid_segment?/1) do
      duration = Enum.sum(Enum.map(segments, &elem(&1, 0)))
      bytes = Enum.sum(Enum.map(segments, &elem(&1, 1)))
      peaks = peak_rates(segments, target)

      %{
        bandwidth: ceil(Enum.max(peaks, fn -> bytes * 8 / duration end)),
        average_bandwidth: ceil(bytes * 8 / duration)
      }
    else
      _ -> %{}
    end
  end

  defp segments(playlist, sizes) do
    Regex.scan(~r/^#EXTINF:([0-9.]+),[^\r\n]*\r?\n([^\r\n]+)\r?$/m, playlist)
    |> Enum.map(fn [_, duration, name] ->
      case Float.parse(duration) do
        {seconds, ""} -> {seconds, Map.get(sizes, String.trim(name))}
        _ -> {0, nil}
      end
    end)
  end

  defp valid_segment?({duration, bytes}),
    do: duration > 0 and is_integer(bytes) and bytes > 0

  # RFC 8216 peak rate: contiguous windows between 0.5 and 1.5 target durations.
  defp peak_rates([], _target), do: []

  defp peak_rates([_ | rest] = segments, target) do
    window_rates(segments, target, 0, 0) ++ peak_rates(rest, target)
  end

  defp window_rates([], _target, _duration, _bytes), do: []

  defp window_rates([{seconds, size} | rest], target, duration, bytes) do
    duration = duration + seconds
    bytes = bytes + size

    cond do
      duration > 1.5 * target -> []
      duration < 0.5 * target -> window_rates(rest, target, duration, bytes)
      true -> [bytes * 8 / duration | window_rates(rest, target, duration, bytes)]
    end
  end
end
