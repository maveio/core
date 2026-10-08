defmodule MaveCore.Flow.ManifestParity do
  @moduledoc """
  Normalization helpers to compare legacy (`mave`) and new (`core`) manifests.

  We intentionally compare a stable subset of fields and normalized list ordering
  so parity checks are deterministic.
  """

  @doc """
  Returns `true` when manifests are equivalent after normalization.
  """
  def equivalent?(legacy_manifest, core_manifest) do
    normalize(legacy_manifest) == normalize(core_manifest)
  end

  @doc """
  Returns a normalized diff payload.
  """
  def diff(legacy_manifest, core_manifest) do
    legacy = normalize(legacy_manifest)
    core = normalize(core_manifest)

    if legacy == core do
      :equal
    else
      %{legacy: legacy, core: core}
    end
  end

  @doc """
  Normalizes a manifest to a parity-comparison shape.
  """
  def normalize(manifest) when is_map(manifest) do
    video = value(manifest, "video")
    poster = value(manifest, "poster")

    %{
      "id" => value(manifest, "id"),
      "space_id" => value(manifest, "space_id"),
      "name" => value(manifest, "name"),
      "metrics_key" => value(manifest, "metrics_key"),
      "settings" => %{
        "aspect_ratio" => value(value(manifest, "settings"), "aspect_ratio")
      },
      "video" => %{
        "id" => value(video, "id"),
        "version" => value(video, "version"),
        "aspect_ratio" => value(video, "aspect_ratio"),
        "duration" => value(video, "duration"),
        "filetype" => value(video, "filetype"),
        "size" => value(video, "size"),
        "renditions" => normalize_video_renditions(value(video, "renditions"))
      },
      "poster" => %{
        "image_src" => value(poster, "image_src"),
        "initial_frame_src" => value(poster, "initial_frame_src"),
        "type" => value(poster, "type"),
        "video_src" => value(poster, "video_src"),
        "renditions" => normalize_poster_renditions(value(poster, "renditions"))
      },
      "subtitles" => normalize_lang_assets(value(manifest, "subtitles")),
      "audio_tracks" => normalize_lang_assets(value(manifest, "audio_tracks"))
    }
  end

  def normalize(_), do: %{}

  defp normalize_video_renditions(renditions) when is_list(renditions) do
    renditions
    |> Enum.map(fn rendition ->
      %{
        "type" => value(rendition, "type"),
        "size" => value(rendition, "size"),
        "codec" => value(rendition, "codec"),
        "container" => value(rendition, "container"),
        "src" => value(rendition, "src"),
        "file_size" => value(rendition, "file_size")
      }
    end)
    |> Enum.sort_by(fn rendition ->
      {
        rendition["type"],
        rendition["size"],
        rendition["codec"],
        rendition["container"],
        rendition["src"]
      }
    end)
  end

  defp normalize_video_renditions(_), do: []

  defp normalize_poster_renditions(renditions) when is_list(renditions) do
    renditions
    |> Enum.map(fn rendition ->
      %{
        "type" => value(rendition, "type"),
        "container" => value(rendition, "container"),
        "date" => value(rendition, "date"),
        "src" => value(rendition, "src"),
        "file_size" => value(rendition, "file_size")
      }
    end)
    |> Enum.sort_by(fn rendition ->
      {rendition["type"], rendition["container"], rendition["date"], rendition["src"]}
    end)
  end

  defp normalize_poster_renditions(_), do: []

  defp normalize_lang_assets(items) when is_list(items) do
    items
    |> Enum.map(fn item ->
      %{
        "id" => value(item, "id"),
        "language" => value(item, "language"),
        "label" => value(item, "label"),
        "src" => value(item, "src")
      }
    end)
    |> Enum.sort_by(fn item -> {item["language"], item["id"], item["label"], item["src"]} end)
  end

  defp normalize_lang_assets(_), do: []

  defp value(nil, _key), do: nil

  defp value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        map
        |> Map.keys()
        |> Enum.find_value(&atom_string_map_value(map, &1, key))
    end
  end

  defp value(_, _key), do: nil

  defp atom_string_map_value(map, map_key, key) when is_atom(map_key) do
    if Atom.to_string(map_key) == key, do: Map.get(map, map_key), else: nil
  end

  defp atom_string_map_value(_map, _map_key, _key), do: nil
end
