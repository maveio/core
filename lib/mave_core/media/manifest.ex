defmodule MaveCore.Media.Manifest do
  @moduledoc """
  Structs and parsing logic for the Video Manifest JSON.
  """

  defstruct [
    :id,
    :name,
    :poster,
    :settings,
    :video,
    :audio_tracks,
    :subtitles,
    :created_at
  ]

  @fields [
    :id,
    :name,
    :poster,
    :settings,
    :video,
    :audio_tracks,
    :subtitles,
    :created_at
  ]

  defmodule StartFrame do
    @moduledoc false
    defstruct [:image_src, :renditions]
  end

  @doc """
  Returns the base path for assets based on the manifest version.
  When version > 0, assets are located in `embed_hash/vN/`, otherwise just `embed_hash/`.
  """
  def asset_base_path(embed_hash, %__MODULE__{video: %{version: version}})
      when is_integer(version) and version > 0 do
    Path.join(embed_hash, "v#{version}")
  end

  def asset_base_path(embed_hash, _manifest), do: embed_hash

  def parse(data) when is_map(data), do: parse_map(data)

  def parse(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} -> parse(data)
      {:error, _} = err -> err
    end
  end

  defp parse_map(data) do
    {:ok, struct(__MODULE__, normalize_fields(data))}
  rescue
    error -> {:error, error}
  end

  defp normalize_fields(data) do
    Enum.reduce(@fields, %{}, fn field, acc ->
      case fetch_field(data, field) do
        {:ok, value} -> Map.put(acc, field, normalize_field_value(field, value))
        :error -> acc
      end
    end)
  end

  defp fetch_field(data, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(data, field) -> {:ok, Map.fetch!(data, field)}
      Map.has_key?(data, string_field) -> {:ok, Map.fetch!(data, string_field)}
      true -> :error
    end
  end

  defp normalize_field_value(:video, value) when is_map(value) do
    case Map.fetch(value, "version") do
      {:ok, version} -> Map.put(value, :version, version)
      :error -> value
    end
  end

  defp normalize_field_value(_field, value), do: value
end
