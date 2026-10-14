defmodule MaveCore.Transcription.SubtitleTranslations do
  @moduledoc "Version-bound subtitle translation requests and selective publication."

  import Ecto.Query
  alias MaveCore.{Assets, Embeds, Flow, Languages, LegacyShortUUID, Repo, UsageLimits}
  alias MaveCore.Assets.{Asset, Subtitle}
  alias MaveCore.Embeds.{Embed, Events, ManifestPublisher}
  alias MaveCore.Flow.Run
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.Space
  alias MaveCore.Transcription.SubtitleSource

  @operation "subtitle_translation"
  @active_statuses ["queued", "running"]

  def request(%Space{} = space, %Embed{} = embed, source_id, targets, opts \\ []) do
    with {:ok, targets} <- normalize_targets(targets) do
      Repo.transaction(fn ->
        current = locked_embed!(space.id, embed.id)
        ensure_ready!(current)
        ensure_publishing_finished!(current)
        source = source_for_video!(current, source_id)
        ensure_targets_available!(current, source, targets)
        check_usage!(space, current, targets)
        Enum.map(targets, &start_translation!(current, source, &1, opts))
      end)
    end
  end

  def list(%Space{id: space_id}, %Embed{id: embed_id, space_id: space_id}) do
    from(r in Run,
      where: fragment("?->>'operation'", r.input) == @operation,
      where: fragment("?->>'embed_id'", r.input) == ^embed_id,
      order_by: [desc: r.inserted_at],
      limit: 30,
      select: %{
        id: r.id,
        status: r.status,
        target: fragment("?->>'target_language'", r.input),
        video_id: fragment("?->>'video_id'", r.input)
      }
    )
    |> Repo.all()
  end

  def list(_space, _embed), do: []

  def target_languages(%Space{id: space_id}, %Embed{space_id: space_id} = embed) do
    embed = Repo.preload(embed, :asset)
    video_id = embed.asset && embed.asset.current_video_id

    unavailable =
      Assets.all_subtitles_for_video(video_id)
      |> Enum.map(&base_language(&1.language))
      |> Enum.concat(active_languages(video_id))

    Enum.reject(Languages.spoken_languages(), fn {_label, language} -> language in unavailable end)
  end

  def target_languages(_space, _embed), do: []

  def authorize_execution(%{"operation" => @operation} = input) do
    case Repo.get_by(Embed, id: input["embed_id"], space_id: input["space_id"]) do
      nil -> {:error, :embed_not_found}
      embed -> authorize_current_video(Repo.preload(embed, [:space, :asset]), input)
    end
  end

  def authorize_execution(_input), do: {:error, :invalid_translation_request}

  def load_source(input) do
    with {:ok, embed} <- authorize_execution(input),
         {:ok, key} <- source_key(input, embed),
         {:ok, body} <- storage().get(bucket(embed), key, embed.space.region),
         {:ok, normalized} <- SubtitleSource.parse(normalize_body(body)),
         json_key = output_prefix(input) <> "/source.json",
         {:ok, _} <-
           storage().put(
             bucket(embed),
             json_key,
             Jason.encode!(normalized),
             "application/json",
             embed.space.region
           ) do
      {:ok,
       %{
         "status" => "ok",
         "language" => input["source_language"],
         "subtitle_json_key" => json_key
       }}
    end
  end

  def publish(input, %{"status" => "ok", "subtitle_key" => key}) do
    result =
      Repo.transaction(fn ->
        embed = locked_embed!(input["space_id"], input["embed_id"])
        ensure_current_video!(embed, input)
        ensure_publishing_finished!(embed)
        ensure_output_key!(key, input)
        subtitle = add_translated_subtitle!(embed, input, key)
        refresh_outputs!(embed)
        subtitle
      end)

    case result do
      {:ok, subtitle} ->
        Events.broadcast_updated(input["space_id"], input["embed_id"], %{
          "action" => "subtitle_translated"
        })

        {:ok, subtitle}

      error ->
        error
    end
  end

  def publish(_input, _output), do: {:error, :translation_output_missing}

  def output_prefix(input) do
    prefix =
      if input["version"] > 0,
        do: "#{input["embed_hash"]}/v#{input["version"]}",
        else: input["embed_hash"]

    prefix <> "/translations/" <> input["translation_id"]
  end

  defp locked_embed!(space_id, embed_id) do
    case Repo.get_by(Embed, id: embed_id, space_id: space_id) do
      %Embed{asset_id: asset_id, deleted_at: nil} = embed when is_binary(asset_id) ->
        Repo.one!(from(a in Asset, where: a.id == ^asset_id, lock: "FOR UPDATE"))
        Repo.preload(embed, [:space, asset: [:current_video]], force: true)

      _ ->
        Repo.rollback(:embed_not_found)
    end
  end

  defp source_for_video!(embed, source_id) do
    with {:ok, id} <- LegacyShortUUID.cast(source_id),
         %Subtitle{} = subtitle <- Assets.get_subtitle_for_video(id, embed.asset.current_video_id) do
      subtitle
    else
      _ -> Repo.rollback(:source_subtitle_not_found)
    end
  end

  defp ensure_ready!(%{asset: %{current_video: %{status: status}}})
       when status in ["ready", "playable"], do: :ok

  defp ensure_ready!(_), do: Repo.rollback(:video_not_ready)

  defp ensure_publishing_finished!(embed) do
    if publishing_active?(embed), do: Repo.rollback(:video_still_publishing)
  end

  defp publishing_active?(embed) do
    from(r in Run,
      where: r.status in @active_statuses,
      where: fragment("COALESCE(?->>'operation', '')", r.input) != @operation,
      where:
        fragment("?->>'video_id'", r.input) == ^embed.asset.current_video_id or
          fragment("?->>'embed_id'", r.input) == ^embed.id or
          (fragment("?->>'space_hash'", r.input) == ^embed.space.hash and
             fragment("?->>'embed_hash'", r.input) == ^embed.hash)
    )
    |> Repo.exists?()
  end

  defp normalize_targets(targets) when is_list(targets) and targets != [] do
    allowed = Enum.map(Languages.spoken_languages(), &elem(&1, 1))

    normalized =
      Enum.map(targets, fn value ->
        if is_binary(value), do: String.downcase(String.trim(value)), else: nil
      end)

    if Enum.all?(normalized, &(&1 in allowed)),
      do: {:ok, Enum.uniq(normalized)},
      else: {:error, :invalid_target_language}
  end

  defp normalize_targets(_), do: {:error, :target_languages_required}

  defp ensure_targets_available!(embed, source, targets) do
    existing =
      Assets.all_subtitles_for_video(embed.asset.current_video_id)
      |> Enum.map(&base_language(&1.language))

    active = active_languages(embed.asset.current_video_id)

    cond do
      Enum.any?(targets, &(&1 == base_language(source.language))) ->
        Repo.rollback(:source_language_selected)

      Enum.any?(targets, &(&1 in existing)) ->
        Repo.rollback(:target_language_exists)

      Enum.any?(targets, &(&1 in active)) ->
        Repo.rollback(:translation_already_running)

      true ->
        :ok
    end
  end

  defp active_languages(nil), do: []

  defp active_languages(video_id) do
    from(r in Run,
      where: r.status in @active_statuses,
      where: fragment("?->>'operation'", r.input) == @operation,
      where: fragment("?->>'video_id'", r.input) == ^video_id,
      select: fragment("?->>'target_language'", r.input)
    )
    |> Repo.all()
  end

  defp check_usage!(space, embed, targets) do
    case UsageLimits.can_translate_subtitles?(space, %{
           video_id: embed.asset.current_video_id,
           target_languages: targets
         }) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:translation_not_allowed, reason})
    end
  end

  defp start_translation!(embed, source, target, opts) do
    input = %{
      "operation" => @operation,
      "space_id" => embed.space_id,
      "embed_id" => embed.id,
      "space_hash" => embed.space.hash,
      "embed_hash" => embed.hash,
      "region" => embed.space.region,
      "video_id" => embed.asset.current_video_id,
      "version" => Embeds.current_video_version(embed),
      "source_subtitle_id" => source.id,
      "source_path" => source.path,
      "source_language" => source.language,
      "target_language" => target,
      "translation_id" => LegacyShortUUID.generate()
    }

    case Flow.start_run("translate_subtitle", input, Keyword.take(opts, [:enqueue])) do
      {:ok, run} -> run
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_current_video(
         %Embed{deleted_at: nil, asset: %{current_video_id: id}} = embed,
         %{"video_id" => id} = input
       ) do
    with false <- publishing_active?(embed),
         {:ok, _} <- LegacyShortUUID.cast(input["translation_id"]),
         :ok <-
           UsageLimits.can_translate_subtitles?(embed.space, %{
             video_id: id,
             target_languages: [input["target_language"]]
           }) do
      {:ok, embed}
    else
      true -> {:error, :video_still_publishing}
      :error -> {:error, :invalid_translation_request}
      {:error, reason} -> {:error, {:translation_not_allowed, reason}}
    end
  end

  defp authorize_current_video(_embed, _input), do: {:error, :video_replaced}

  defp ensure_current_video!(embed, input) do
    if embed.asset.current_video_id != input["video_id"], do: Repo.rollback(:video_replaced)
  end

  defp source_key(input, embed) do
    path = input["source_path"] || ""
    key = String.replace_prefix(path, "s3://#{bucket(embed)}/", "")

    prefix =
      if input["version"] > 0, do: "#{embed.hash}/v#{input["version"]}/", else: embed.hash <> "/"

    if String.starts_with?(key, prefix) and not String.contains?(key, ["..", "?", "#"]),
      do: {:ok, key},
      else: {:error, :invalid_subtitle_path}
  end

  defp ensure_output_key!(key, input) do
    expected = output_prefix(input) <> "/subtitle_#{input["target_language"]}.vtt"
    if key != expected, do: Repo.rollback(:invalid_translation_output)
  end

  defp add_translated_subtitle!(embed, input, key) do
    existing =
      Repo.get_by(Subtitle, video_id: input["video_id"], language: input["target_language"])

    case existing do
      %Subtitle{path: ^key, source: "translated"} = subtitle ->
        subtitle

      %Subtitle{} ->
        Repo.rollback(:target_language_exists)

      nil ->
        attrs = %{
          video_id: embed.asset.current_video_id,
          language: input["target_language"],
          path: key,
          source: "translated"
        }

        case Assets.create_subtitle(attrs) do
          {:ok, subtitle} -> subtitle
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp refresh_outputs!(embed) do
    with :ok <- Assets.refresh_hls_master_playlist(embed, strict: true),
         {:ok, _} <- ManifestPublisher.publish(embed) do
      :ok
    else
      {:error, reason} -> Repo.rollback({:translation_publication_failed, reason})
    end
  end

  defp base_language(nil), do: nil

  defp base_language(language),
    do: language |> String.downcase() |> String.split(~r/[-_]/, parts: 2) |> hd()

  defp normalize_body(body) when is_map(body), do: Jason.encode!(body)
  defp normalize_body(body), do: body
  defp bucket(embed), do: Storage.bucket_for_space(embed.space.hash, embed.space.region)
  defp storage, do: Application.get_env(:mave_core, :flow_storage_adapter, Storage)
end
