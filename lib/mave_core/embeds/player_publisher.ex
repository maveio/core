defmodule MaveCore.Embeds.PlayerPublisher do
  @moduledoc false

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Experiments

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

    # The page at the embed root is what iframe embeds load. Whoever publishes
    # it, a running or locked A/B test keeps deciding which video it plays.
    experiment =
      if normalize_version(version) == 0 do
        Keyword.get_lazy(opts, :experiment, fn ->
          Experiments.player_state(space_hash, embed_hash)
        end)
      end

    body =
      player_html(space_hash, embed_hash, Keyword.get(opts, :audio_only, false), experiment)

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

  defp player_html(_space_hash, _embed_hash, _audio_only?, %{locked: public_id}) do
    page(config_script(), player_element("mave-player", public_id))
  end

  # Each viewer gets one variant at random and keeps it on later visits. The
  # variant plays under its own embed ID, which is how its views are measured.
  defp player_html(_space_hash, _embed_hash, _audio_only?, %{id: id, variants: variants}) do
    script = """
    <script type="module">
          import { configureMave } from "#{SettingsSerializer.component_config_src()}";
          configureMave(#{SettingsSerializer.component_config_json()});
          const experiment = #{Jason.encode!(%{id: id, variants: variants}, escape: :html_safe)};
          const key = "mave:experiment:" + experiment.id;
          let embed = null;
          try { embed = window.localStorage.getItem(key); } catch (_error) {}
          if (!experiment.variants.includes(embed)) {
            embed = experiment.variants[Math.floor(Math.random() * experiment.variants.length)];
            try { window.localStorage.setItem(key, embed); } catch (_error) {}
          }
          const player = document.createElement("mave-player");
          player.setAttribute("embed", embed);
          player.style.width = "100%";
          document.body.appendChild(player);
          await import("#{SettingsSerializer.component_src()}");
        </script>
    """

    page(String.trim_trailing(script), "")
  end

  defp player_html(space_hash, embed_hash, audio_only?, _experiment) do
    tag = if audio_only?, do: "mave-audio", else: "mave-player"

    page(
      config_script(),
      player_element(tag, SettingsSerializer.public_embed_id(space_hash, embed_hash))
    )
  end

  defp config_script do
    """
    <script type="module">
          import { configureMave } from "#{SettingsSerializer.component_config_src()}";
          configureMave(#{SettingsSerializer.component_config_json()});
          await import("#{SettingsSerializer.component_src()}");
        </script>
    """
    |> String.trim_trailing()
  end

  defp player_element(tag, public_id),
    do: ~s(<#{tag} embed="#{public_id}" style="width: 100%;"></#{tag}>)

  defp page(script, body) do
    """
    <!doctype html>
    <html lang="en" style="background: transparent;">
      <head>
        <title>Player</title>
        <meta name="robots" content="noindex,nofollow">
        #{script}
      </head>
      <body style="background: transparent; height: 100vh; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center;">
        #{body}
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
