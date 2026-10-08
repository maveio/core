defmodule MaveCore.Media.Playlist do
  @moduledoc """
  Parses HLS Playlists to find segments for a given timestamp.
  """

  @doc """
  Given a variant playlist content and a time (seconds), return the segment URL (relative)
  and its duration info.
  """
  def segment_at_time(playlist_content, time_seconds) do
    lines = String.split(playlist_content, "\n")
    init_segment = find_init_segment(lines)

    case find_segment(lines, time_seconds, 0.0) do
      {:ok, info} -> {:ok, Map.put(info, :init, init_segment)}
      err -> err
    end
  end

  defp find_init_segment(lines) do
    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, "#EXT-X-MAP:URI="), do: parse_init_segment_uri(line)
    end)
  end

  defp parse_init_segment_uri(line) do
    case String.split(line, "URI=\"") do
      [_, uri_part] -> String.replace(uri_part, "\"", "")
      _ -> nil
    end
  end

  defp find_segment(lines, target, current, last_valid_segment \\ nil)

  defp find_segment([], _target, _current, last_valid_segment) do
    if last_valid_segment do
      {:ok, last_valid_segment}
    else
      {:error, :out_of_range}
    end
  end

  defp find_segment([line | rest], target, current, last_valid_segment) do
    if String.starts_with?(line, "#EXTINF:") do
      duration = parse_duration(line)
      next_line = Enum.at(rest, 0)
      updated_last_segment = %{segment: next_line, start: current, duration: duration}

      if current + duration > target do
        {:ok, updated_last_segment}
      else
        find_segment(rest, target, current + duration, updated_last_segment)
      end
    else
      find_segment(rest, target, current, last_valid_segment)
    end
  end

  defp parse_duration(line) do
    # #EXTINF:6.000000,
    line
    |> String.replace("#EXTINF:", "")
    |> String.replace(",", "")
    |> String.trim()
    |> String.to_float()
  rescue
    _ -> 0.0
  end

  @doc """
  Selects the best variant from a root playlist content based on options.
  Options can include `width` (integer) to find the closest resolution.
  Returns `{:ok, uri, resolution}` where resolution is `{width, height}` or `nil`.
  """
  def select_variant(root_content, opts \\ []) do
    target_width = opts[:width]

    variants =
      root_content
      |> String.split("\n")
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(&variant_entry/1)

    selected =
      if target_width do
        select_variant_by_width(variants, target_width)
      else
        select_highest_bandwidth_variant(variants)
      end

    case selected do
      %{uri: uri, resolution: resolution} -> {:ok, uri, resolution}
      nil -> {:error, :no_variant_found}
    end
  end

  defp variant_entry([line1, line2]) do
    if String.starts_with?(line1, "#EXT-X-STREAM-INF") do
      [
        %{
          bandwidth: parse_attribute(line1, "BANDWIDTH"),
          resolution: parse_resolution(line1),
          uri: String.trim(line2)
        }
      ]
    else
      []
    end
  end

  defp select_variant_by_width(variants, target_width) do
    Enum.min_by(variants, &variant_width_distance(&1, target_width), fn -> nil end)
  end

  defp select_highest_bandwidth_variant(variants) do
    Enum.max_by(variants, & &1.bandwidth, fn -> nil end)
  end

  defp variant_width_distance(%{resolution: {width, _height}}, target_width) do
    abs(width - target_width)
  end

  defp variant_width_distance(_variant, _target_width), do: 1_000_000

  @doc """
  Clamps the width/height options to not exceed the maximum resolution.
  """
  def clamp_opts(opts, nil), do: opts

  def clamp_opts(opts, {max_w, max_h}) do
    opts
    |> Keyword.update(:width, nil, fn
      nil -> nil
      w -> min(w, max_w)
    end)
    |> Keyword.update(:height, nil, fn
      nil -> nil
      h -> min(h, max_h)
    end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp parse_attribute(line, key) do
    case Regex.run(~r/#{key}=(\d+)/, line) do
      [_, val] -> String.to_integer(val)
      _ -> 0
    end
  end

  defp parse_resolution(line) do
    case Regex.run(~r/RESOLUTION=(\d+)x(\d+)/, line) do
      [_, w, h] -> {String.to_integer(w), String.to_integer(h)}
      _ -> nil
    end
  end
end
