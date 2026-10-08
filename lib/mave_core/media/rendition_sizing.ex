defmodule MaveCore.Media.RenditionSizing do
  @moduledoc false

  @profile_long_edges %{
    "sd" => 640,
    "hd" => 1280,
    "fhd" => 1920,
    "qhd" => 2560,
    "uhd" => 3840
  }
  @profile_sizes ~w(sd hd fhd qhd uhd)

  @normalize_sar_filter "scale=iw*sar:ih,setsar=1"

  def normalize_sar_filter, do: @normalize_sar_filter

  def long_edge_scale_filter(size) when is_binary(size) do
    with {:ok, long_edge} <- target_long_edge(size) do
      {:ok, long_edge_scale_filter(long_edge)}
    end
  end

  def long_edge_scale_filter(long_edge) when is_integer(long_edge) and long_edge > 0 do
    "#{@normalize_sar_filter},scale=w=#{long_edge}:h=#{long_edge}:force_original_aspect_ratio=decrease:force_divisible_by=2"
  end

  def long_edge_scale_filter(_long_edge), do: {:error, :invalid_long_edge}

  def target_long_edge(size) do
    case Map.get(@profile_long_edges, size) do
      nil -> {:error, {:unsupported_size, size}}
      long_edge -> {:ok, long_edge}
    end
  end

  def capped_target_long_edge(size, source_metadata) do
    with {:ok, target_long_edge} <- target_long_edge(size) do
      case source_long_edge(source_metadata) do
        source_long_edge when is_integer(source_long_edge) ->
          {:ok, even_dimension(min(source_long_edge, target_long_edge))}

        _other ->
          {:ok, target_long_edge}
      end
    end
  end

  def source_dimensions(%{} = metadata) do
    with {:ok, width} <- positive_integer(map_get(metadata, "width")),
         {:ok, height} <- positive_integer(map_get(metadata, "height")) do
      {:ok, {width, height}}
    end
  end

  def source_dimensions(_metadata), do: {:error, :missing_source_dimensions}

  def source_long_edge(%{} = metadata) do
    case source_dimensions(metadata) do
      {:ok, {width, height}} ->
        max(width, height)

      {:error, _reason} ->
        case source_dimension_values(metadata) do
          [] -> nil
          values -> Enum.max(values)
        end
    end
  end

  def source_long_edge(_metadata), do: nil

  def source_allows_size?(metadata, size) do
    with source_long_edge when is_integer(source_long_edge) <- source_long_edge(metadata),
         {:ok, minimum_source_long_edge} <- minimum_source_long_edge(size) do
      source_long_edge > minimum_source_long_edge
    else
      _ -> false
    end
  end

  def source_below_variant?(metadata, size) do
    with source_long_edge when is_integer(source_long_edge) <- source_long_edge(metadata),
         {:ok, target_long_edge} <- target_long_edge(size) do
      target_long_edge > Map.fetch!(@profile_long_edges, "sd") and
        not source_allows_size?(metadata, size)
    else
      _ -> false
    end
  end

  def filter_sizes(requested_sizes, nil, _require_source_resolution?), do: requested_sizes

  def filter_sizes(requested_sizes, source_metadata, require_source_resolution?)
      when is_map(source_metadata) do
    case source_long_edge(source_metadata) do
      nil ->
        requested_sizes

      _source_long_edge ->
        do_filter_sizes(requested_sizes, source_metadata, require_source_resolution?)
    end
  end

  def filter_sizes(requested_sizes, _source_metadata, _require_source_resolution?),
    do: requested_sizes

  defp do_filter_sizes(requested_sizes, source_metadata, true) do
    Enum.filter(requested_sizes, &source_allows_size?(source_metadata, &1))
  end

  defp do_filter_sizes([base_size | _] = requested_sizes, source_metadata, false) do
    Enum.filter(requested_sizes, fn size ->
      size == base_size or source_allows_size?(source_metadata, size)
    end)
  end

  defp do_filter_sizes([], _source_metadata, _require_source_resolution?), do: []

  def scaled_resolution(size, source_metadata) do
    with {:ok, target_long_edge} <- capped_target_long_edge(size, source_metadata),
         {:ok, {source_width, source_height}} <- source_dimensions(source_metadata) do
      {width, height} = scale_dimensions(source_width, source_height, target_long_edge)
      {:ok, "#{width}x#{height}"}
    end
  end

  defp minimum_source_long_edge(size) do
    case Enum.find_index(@profile_sizes, &(&1 == size)) do
      nil ->
        {:error, {:unsupported_size, size}}

      0 ->
        {:ok, 0}

      index ->
        previous_size = Enum.at(@profile_sizes, index - 1)
        target_long_edge(previous_size)
    end
  end

  defp scale_dimensions(source_width, source_height, target_long_edge)
       when source_width >= source_height do
    width = target_long_edge
    height = even_dimension(source_height * width / source_width)
    {width, height}
  end

  defp scale_dimensions(source_width, source_height, target_long_edge) do
    height = target_long_edge
    width = even_dimension(source_width * height / source_height)
    {width, height}
  end

  defp even_dimension(value) do
    value
    |> round()
    |> div(2)
    |> max(1)
    |> Kernel.*(2)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_positive_integer}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_positive_integer}

  defp positive_integer_value(value) do
    case positive_integer(value) do
      {:ok, integer} -> integer
      {:error, _reason} -> nil
    end
  end

  defp source_dimension_values(metadata) do
    ["width", "height"]
    |> Enum.map(&(metadata |> map_get(&1) |> positive_integer_value()))
    |> Enum.reject(&is_nil/1)
  end

  defp map_get(map, "width"), do: Map.get(map, "width") || Map.get(map, :width)
  defp map_get(map, "height"), do: Map.get(map, "height") || Map.get(map, :height)
end
