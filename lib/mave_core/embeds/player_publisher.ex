defmodule MaveCore.Embeds.PlayerPublisher do
  @moduledoc false

  alias MaveCore.Embeds.SettingsSerializer

  @spec publish(
          module(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def publish(storage_adapter, bucket, space_hash, embed_hash, version, region, opts \\ [])
      when is_atom(storage_adapter) and is_binary(bucket) and is_binary(space_hash) and
             is_binary(embed_hash) do
    key = player_key(embed_hash, version)
    body = player_html(space_hash, embed_hash, Keyword.get(opts, :audio_only, false))

    case storage_adapter.put_public(bucket, key, body, "text/html", region) do
      {:ok, _body} ->
        {:ok,
         %{
           "player_key" => key,
           "player_uri" => "s3://#{bucket}/#{key}",
           "size_bytes" => byte_size(body)
         }}

      {:error, reason} ->
        {:error, {:player_upload_failed, reason}}
    end
  end

  defp player_html(space_hash, embed_hash, audio_only?) do
    tag = if audio_only?, do: "mave-audio", else: "mave-player"

    """
    <!doctype html>
    <html lang="en" style="background: transparent;">
      <head>
        <title>Player</title>
        <meta name="robots" content="noindex,nofollow">
        <script type="module">
          import { configureMave } from "#{SettingsSerializer.component_config_src()}";
          configureMave(#{SettingsSerializer.component_config_json()});
          await import("#{SettingsSerializer.component_src()}");
        </script>
      </head>
      <body style="background: transparent; height: 100vh; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center;">
        <#{tag} embed="#{SettingsSerializer.public_embed_id(space_hash, embed_hash)}" style="width: 100%;"></#{tag}>
      </body>
    </html>
    """
  end

  defp player_key(embed_hash, version) do
    if normalize_version(version) > 0 do
      "#{embed_hash}/v#{normalize_version(version)}/player.html"
    else
      "#{embed_hash}/player.html"
    end
  end

  defp normalize_version(version) when is_integer(version) and version > 0, do: version

  defp normalize_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_version(_version), do: 0
end
