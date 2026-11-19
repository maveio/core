defmodule MaveCore.Chapters do
  @moduledoc """
  Video chapters: suggested from the transcript, reviewed by a person, and then
  published so viewers can jump to a part of the video.

  Suggestions and edits live in a draft that is never visible to viewers.
  Publishing copies the draft to the published chapters, writes `chapters.vtt`
  next to the video and lists the chapters in the manifest. Chapters belong to
  one video version, so a replacement video starts without chapters.

  See `docs/chapters.md`.
  """

  alias MaveCore.Assets
  alias MaveCore.Assets.{ChapterSet, Video}
  alias MaveCore.AudioDescription
  alias MaveCore.Chapters.{Suggester, Transcript}
  alias MaveCore.Embeds
  alias MaveCore.Embeds.{Embed, Events, ManifestPublisher, SettingsSerializer}
  alias MaveCore.Media.Storage
  alias MaveCore.Repo
  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits
  alias MaveCore.Workers.ChapterSuggestionWorker

  @vtt_filename "chapters.vtt"

  # --- Reading ------------------------------------------------------------

  @doc "The chapter set of a video version, or `nil` when it has none yet."
  def get_set(video_id) when is_binary(video_id), do: Repo.get_by(ChapterSet, video_id: video_id)
  def get_set(_video_id), do: nil

  @doc "The chapter set of the embed's current video."
  def get_set_for_embed(%Embed{} = embed) do
    case embed |> preload() |> current_video() do
      %Video{id: video_id} -> get_set(video_id)
      _ -> nil
    end
  end

  @doc "Whether the draft differs from what viewers currently get."
  def unpublished_changes?(%ChapterSet{draft: draft, published: published}),
    do: draft != published

  def unpublished_changes?(_set), do: false

  @doc """
  Published chapters with end times: `[%{"start" => s, "end" => s, "title" => t}]`.
  A chapter ends where the next one starts; the last one ends with the video.
  """
  def cues(chapters, duration) when is_list(chapters) do
    chapters
    |> Enum.zip(Enum.drop(chapters, 1) ++ [nil])
    |> Enum.map(fn {chapter, next} ->
      finish =
        case next do
          %{"start" => next_start} -> next_start
          nil -> last_end(chapter["start"], duration)
        end

      %{"start" => chapter["start"], "end" => finish, "title" => chapter["title"]}
    end)
  end

  defp last_end(start, duration) when is_number(duration) and duration > start, do: duration
  defp last_end(start, _duration), do: start + 1

  @doc "The published chapters of a video version with end times; `[]` without any."
  def published_cues(%Video{} = video) do
    case get_set(video.id) do
      %ChapterSet{published: [_ | _] = published} -> cues(published, video.duration)
      _ -> []
    end
  end

  def published_cues(_video), do: []

  @doc "The manifest entry for published chapters, or `nil` without any."
  def published_payload(%Embed{} = embed, version) do
    with %Video{} = video <- current_video(embed),
         %ChapterSet{published: [_ | _] = published} = set <- get_set(video.id) do
      bucket = Storage.bucket_for_space(embed.space.hash, embed.space.region)
      url = SettingsSerializer.storage_object_url(bucket, vtt_key(embed.hash, version))

      %{
        "path" => cache_busted(url, set.published_at),
        "cues" => cues(published, video.duration)
      }
    else
      _ -> nil
    end
  end

  defp cache_busted(url, %DateTime{} = at), do: "#{url}?e=#{DateTime.to_unix(at, :microsecond)}"
  defp cache_busted(url, _at), do: url

  # --- Editing ------------------------------------------------------------

  @doc """
  Replaces the draft with `chapters` (`%{"start" => seconds, "title" => text}`).
  Chapters are sorted by start time; published chapters stay as they are.
  """
  def save_draft(%Video{} = video, chapters) when is_list(chapters) do
    with {:ok, chapters} <- normalize(chapters, video.duration) do
      upsert(video, %{draft: chapters})
    end
  end

  defp normalize(chapters, duration) do
    normalized =
      Enum.map(chapters, fn chapter ->
        %{
          "start" => chapter["start"] || chapter[:start],
          "title" => Suggester.clean_title(chapter["title"] || chapter[:title])
        }
      end)

    with :ok <- validate(normalized, duration) do
      {:ok,
       normalized
       |> Enum.map(&Map.update!(&1, "start", fn start -> Float.round(start * 1.0, 3) end))
       |> Enum.sort_by(& &1["start"])}
    end
  end

  defp validate(chapters, duration) do
    cond do
      not Enum.all?(chapters, &valid_start?/1) -> {:error, :invalid_start}
      Enum.any?(chapters, &(&1["title"] == "")) -> {:error, :missing_title}
      Enum.any?(chapters, &after_end?(&1, duration)) -> {:error, :start_after_end}
      duplicate_starts?(chapters) -> {:error, :duplicate_start}
      true -> :ok
    end
  end

  defp valid_start?(%{"start" => start}), do: is_number(start) and start >= 0

  defp after_end?(%{"start" => start}, duration),
    do: is_number(duration) and duration > 0 and start >= duration

  defp duplicate_starts?(chapters) do
    starts = Enum.map(chapters, &Float.round(&1["start"] * 1.0, 3))
    Enum.uniq(starts) != starts
  end

  # --- Publishing ---------------------------------------------------------

  @doc "Makes the draft the chapters viewers get."
  def publish(%Embed{} = embed) do
    embed = preload(embed)

    with %Video{} = video <- current_video(embed),
         %ChapterSet{draft: [_ | _] = draft} <- get_set(video.id),
         :ok <- put_vtt(embed, to_vtt(draft, video.duration)),
         {:ok, set} <- upsert(video, %{published: draft, published_at: DateTime.utc_now()}),
         {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      Events.broadcast_updated(embed.space_id, embed.id)
      {:ok, set}
    else
      nil -> {:error, :no_chapters}
      %ChapterSet{} -> {:error, :no_chapters}
      {:error, _reason} = error -> error
    end
  end

  @doc "Removes the chapters from playback. The draft is kept."
  def unpublish(%Embed{} = embed) do
    embed = preload(embed)

    with %Video{} = video <- current_video(embed),
         {:ok, set} <- upsert(video, %{published: [], published_at: nil}),
         {:ok, _manifest} <- ManifestPublisher.publish(embed) do
      _ = delete_vtt(embed)
      Events.broadcast_updated(embed.space_id, embed.id)
      {:ok, set}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  @doc "A WebVTT chapters document (`kind=\"chapters\"`) for the given chapters."
  def to_vtt(chapters, duration) do
    body =
      chapters
      |> cues(duration)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {cue, number} ->
        "#{number}\n#{vtt_timestamp(cue["start"])} --> #{vtt_timestamp(cue["end"])}\n" <>
          vtt_text(cue["title"])
      end)

    "WEBVTT\n\n" <> body <> "\n"
  end

  defp vtt_text(title) do
    title
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp vtt_timestamp(seconds) do
    millis = round(seconds * 1000)
    hours = div(millis, 3_600_000)
    minutes = millis |> rem(3_600_000) |> div(60_000)
    secs = millis |> rem(60_000) |> div(1000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [hours, minutes, secs, rem(millis, 1000)])
    |> IO.iodata_to_binary()
  end

  defp put_vtt(%Embed{} = embed, body) do
    {storage, bucket, region} = storage(embed)
    key = vtt_key(embed.hash, Embeds.current_video_version(embed))

    case storage.put_public(bucket, key, body, "text/vtt", region) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, {:chapters_upload_failed, reason}}
    end
  end

  defp delete_vtt(%Embed{} = embed) do
    {storage, bucket, region} = storage(embed)
    key = vtt_key(embed.hash, Embeds.current_video_version(embed))

    if function_exported?(storage, :delete_object, 3),
      do: storage.delete_object(bucket, key, region),
      else: :ok
  end

  @doc "Object key of the published chapters file of a video version."
  def vtt_key(embed_hash, version),
    do: "#{AudioDescription.version_prefix(embed_hash, version)}/#{@vtt_filename}"

  # --- Suggesting ---------------------------------------------------------

  @doc "Whether the space gets a chapter suggestion for every new transcript."
  def automatic?(%Space{automatic_chapters_enabled: true} = space),
    do: UsageLimits.can_use_automatic_chapters?(space) == :ok

  def automatic?(_space), do: false

  @doc """
  Queues a new suggestion for the embed's current video. The suggestion replaces
  the draft when it arrives; published chapters are not touched.
  """
  def request_suggestion(%Embed{} = embed) do
    embed = preload(embed)

    with :ok <- UsageLimits.can_use_automatic_chapters?(embed.space),
         %Video{} = video <- current_video(embed),
         {:ok, set} <- upsert(video, %{status: "generating", reason: nil}),
         {:ok, _job} <-
           %{"embed_id" => embed.id, "video_id" => video.id}
           |> ChapterSuggestionWorker.new()
           |> Oban.insert() do
      {:ok, get_set(video.id) || set}
    else
      nil -> {:error, :missing_current_video}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Requests a first suggestion after a transcript arrived, when the space turned
  automatic chapters on and nobody has worked on this video's chapters yet.
  """
  def maybe_request_automatic_suggestion(%Embed{} = embed, %Video{} = video) do
    embed = preload(embed)

    current_video_id = embed |> current_video() |> then(&(&1 && &1.id))

    with true <- automatic?(embed.space),
         true <- current_video_id == video.id,
         true <- untouched?(get_set(video.id)) do
      request_suggestion(embed)
    else
      _ -> :ok
    end
  end

  defp untouched?(nil), do: true

  defp untouched?(%ChapterSet{} = set) do
    set.draft == [] and set.published == [] and is_nil(set.generated_at) and
      set.status != "generating"
  end

  @doc """
  Suggests chapters for `video_id` now and stores them as the draft. Called by
  `MaveCore.Workers.ChapterSuggestionWorker`.
  """
  def generate(%Embed{} = embed, video_id, opts \\ []) when is_binary(video_id) do
    embed = preload(embed)

    case Repo.get(Video, video_id) do
      %Video{} = video ->
        result =
          with {:ok, cues, language} <- load_transcript(embed, video),
               {:ok, suggestion} <-
                 Suggester.suggest(
                   Keyword.merge(opts,
                     cues: cues,
                     duration: video.duration,
                     language: language || video.language,
                     cuts: load_cuts(embed, video),
                     usage_context: %{
                       space_hash: embed.space.hash,
                       embed_hash: embed.hash,
                       video_id: video.id,
                       step_id: "suggest_chapters"
                     }
                   )
                 ) do
            upsert(video, %{
              draft: suggestion.chapters,
              generator: suggestion.generator,
              inputs: suggestion.inputs,
              language: language || video.language,
              status: "idle",
              reason: nil,
              generated_at: DateTime.utc_now()
            })
          else
            {:error, reason} ->
              upsert(video, %{status: "failed", reason: failure_reason(reason)})
          end

        Events.broadcast_updated(embed.space_id, embed.id)
        result

      nil ->
        {:error, :video_not_found}
    end
  end

  defp failure_reason(reason) when reason in [:no_transcript, :too_short, :no_topic_changes],
    do: Atom.to_string(reason)

  defp failure_reason(_reason), do: "error"

  # The transcript in the video's own language when there is one: translated
  # subtitles would give translated titles at slightly different times.
  defp load_transcript(%Embed{} = embed, %Video{} = video) do
    subtitles = Assets.subtitles_for_video(video.id)

    {preferred, others} =
      Enum.split_with(subtitles, &(is_binary(video.language) and &1.language == video.language))

    (preferred ++ others)
    |> Enum.find_value(fn subtitle ->
      case subtitle_cues(embed, video, subtitle) do
        [] -> nil
        cues -> {:ok, cues, subtitle.language}
      end
    end)
    |> Kernel.||({:error, :no_transcript})
  end

  defp subtitle_cues(%Embed{} = embed, %Video{} = video, subtitle) do
    prefix = AudioDescription.version_prefix(embed.hash, Embeds.current_video_version(video))
    language = subtitle.language || "en"

    case embed |> read("#{prefix}/subtitle_#{language}.json") |> Transcript.from_json() do
      [] -> vtt_cues(embed, [local_path(subtitle.path), "#{prefix}/subtitle_#{language}.vtt"])
      cues -> cues
    end
  end

  defp vtt_cues(%Embed{} = embed, keys) do
    keys
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value([], fn key ->
      case embed |> read(key) |> Transcript.from_vtt() do
        [] -> nil
        cues -> cues
      end
    end)
  end

  defp local_path(path) when is_binary(path) and path != "" do
    if String.starts_with?(path, ["http://", "https://", "s3://"]) or
         Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, path),
       do: nil,
       else: path
  end

  defp local_path(_path), do: nil

  # Scene cuts exist when the audio-description steps analysed this version.
  defp load_cuts(%Embed{} = embed, %Video{} = video) do
    prefix = AudioDescription.work_prefix(embed.hash, Embeds.current_video_version(video))

    case embed |> read("#{prefix}/scenes.json") |> decode() do
      %{"cuts" => cuts} when is_list(cuts) -> Enum.filter(cuts, &is_number/1)
      _ -> []
    end
  end

  defp read(%Embed{} = embed, key) do
    {storage, bucket, region} = storage(embed)

    case storage.get(bucket, key, region) do
      {:ok, body} when is_binary(body) -> body
      {:ok, body} when is_list(body) -> IO.iodata_to_binary(body)
      {:ok, %{} = body} -> body
      _ -> nil
    end
  end

  defp decode(%{} = document), do: document

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = document} -> document
      _ -> nil
    end
  end

  defp decode(_body), do: nil

  # --- Shared -------------------------------------------------------------

  defp upsert(%Video{} = video, attrs) do
    (get_set(video.id) || %ChapterSet{video_id: video.id})
    |> ChapterSet.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp storage(%Embed{} = embed) do
    region = embed.space.region

    {Application.get_env(:mave_core, :flow_storage_adapter, Storage),
     Storage.bucket_for_space(embed.space.hash, region), region}
  end

  defp preload(%Embed{} = embed), do: Repo.preload(embed, [:space, asset: [:current_video]])

  defp current_video(%Embed{asset: %{current_video: %Video{} = video}}), do: video
  defp current_video(_embed), do: nil
end
