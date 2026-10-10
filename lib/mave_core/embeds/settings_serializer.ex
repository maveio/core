defmodule MaveCore.Embeds.SettingsSerializer do
  @moduledoc false

  alias MaveCore.Assets.Video
  alias MaveCore.Embeds.{Embed, EmbedSettings}
  alias MaveCore.Media.Storage
  alias MaveCore.Playback.URLs
  alias MaveCore.Spaces.Space

  @upload_bucket "mave-upload"
  @default_component_cdn_endpoint "https://cdn.video-dns.com/space-${this.spaceId}"
  @default_component_cdn_endpoint_aliases [
    @default_component_cdn_endpoint,
    "https://space-${this.spaceId}.video-dns.com"
  ]

  @spec component_src() :: String.t()
  def component_src do
    case Application.get_env(:mave_core, :components_src) do
      src when is_binary(src) and src != "" ->
        src

      _ ->
        if explicit_component_base_url?() do
          "#{component_base_url()}/dist/index.js"
        else
          "#{component_base_url()}/+esm"
        end
    end
  end

  @spec component_config_src() :: String.t()
  def component_config_src, do: "#{component_base_url()}/dist/config.js"

  @spec component_config_json() :: String.t()
  def component_config_json do
    component_runtime_config()
    |> Jason.encode!()
  end

  @spec component_config_required?() :: boolean()
  def component_config_required? do
    component_src() != default_component_src() or
      not default_component_runtime_config?(component_runtime_config())
  end

  @spec component_runtime_config() :: map()
  def component_runtime_config do
    %{
      "api" => %{"endpoint" => api_endpoint()},
      "cdn" => %{
        "endpoint" => cdn_component_endpoint(),
        "playback_endpoint" => URLs.endpoint(api_endpoint())
      },
      "metrics" => %{"endpoint" => metrics_endpoint()},
      "upload" => %{
        "endpoint" => upload_endpoint(),
        "socket" => upload_socket_endpoint()
      }
    }
  end

  @spec default_component_runtime_config() :: map()
  def default_component_runtime_config do
    %{
      "api" => %{"endpoint" => "https://api.mave.io/api/v1"},
      "cdn" => %{
        "endpoint" => @default_component_cdn_endpoint,
        "playback_endpoint" =>
          "https://space-${this.spaceId}.signed.video-dns.com/${this.embedId}"
      },
      "metrics" => %{"endpoint" => "https://metrics.video-dns.com/v1/events"},
      "upload" => %{
        "endpoint" => "https://upload.mave.io/files",
        "socket" => "wss://dash.mave.io/api/v1/socket"
      }
    }
  end

  @spec react_src() :: String.t()
  def react_src, do: "#{component_base_url()}/dist/react.js"

  @spec vue_src() :: String.t()
  def vue_src, do: "#{component_base_url()}/dist/vue.js"

  @spec settings_struct(Embed.t() | EmbedSettings.t() | map() | nil) :: EmbedSettings.t()
  def settings_struct(%EmbedSettings{} = settings), do: put_time_parts(settings)
  def settings_struct(%Embed{settings: %EmbedSettings{} = settings}), do: put_time_parts(settings)

  def settings_struct(%Embed{space_id: space_id}),
    do: put_time_parts(%EmbedSettings{space_id: space_id})

  def settings_struct(%{space_id: space_id}) when is_binary(space_id),
    do: put_time_parts(%EmbedSettings{space_id: space_id})

  def settings_struct(_), do: put_time_parts(%EmbedSettings{})

  @spec form_values(Embed.t() | EmbedSettings.t() | map() | nil) :: map()
  def form_values(settings_like) do
    settings = settings_struct(settings_like)

    %{
      width: default_string(settings.width, "100%"),
      height: default_string(settings.height, "100%"),
      aspect_ratio_enabled: settings.aspect_ratio_enabled,
      aspect_ratio: default_value(settings.aspect_ratio, :r16_9),
      color: settings.color,
      opacity: default_value(settings.opacity, 100),
      controls_enabled: settings.controls_enabled,
      controls: default_value(settings.controls, :full),
      autoplay_enabled: settings.autoplay_enabled,
      autoplay: default_value(settings.autoplay, :on_show),
      loop_enabled: settings.loop_enabled,
      poster: default_value(settings.poster, :upload),
      poster_time_seconds: default_value(settings.poster_time_seconds, 0.0),
      poster_time_hour: default_value(settings.poster_time_hour, 0),
      poster_time_minute: default_value(settings.poster_time_minute, 0),
      poster_time_second: default_value(settings.poster_time_second, 0.0),
      external_poster: settings.external_poster
    }
  end

  @spec public_embed_id(Space.t() | String.t(), Embed.t() | String.t()) :: String.t()
  def public_embed_id(%Space{hash: space_hash}, %Embed{hash: embed_hash}),
    do: public_embed_id(space_hash, embed_hash)

  def public_embed_id(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    "#{space_hash}#{embed_hash}"
  end

  @spec poster_image_url(Space.t() | String.t(), Embed.t() | String.t(), number()) :: String.t()
  def poster_image_url(%Space{hash: space_hash}, %Embed{hash: embed_hash}, time),
    do: poster_image_url(space_hash, embed_hash, time)

  def poster_image_url(space_hash, embed_hash, time)
      when is_binary(space_hash) and is_binary(embed_hash) do
    "#{poster_image_base_url(space_hash, embed_hash)}?time=#{normalize_time(time)}"
  end

  @spec poster_image_base_url(Space.t() | String.t(), Embed.t() | String.t()) :: String.t()
  def poster_image_base_url(%Space{hash: space_hash}, %Embed{hash: embed_hash}),
    do: poster_image_base_url(space_hash, embed_hash)

  def poster_image_base_url(space_hash, embed_hash)
      when is_binary(space_hash) and is_binary(embed_hash) do
    "#{image_base_url()}/#{public_embed_id(space_hash, embed_hash)}.webp"
  end

  @spec iframe_url(Space.t() | String.t(), Embed.t() | String.t()) :: String.t()
  def iframe_url(%Space{} = space, %Embed{hash: embed_hash}) do
    bucket =
      space.hash
      |> Storage.bucket_for_space(space.region)
      |> bucket_for_public_url()

    "#{storage_bucket_origin(bucket)}/#{embed_hash}/player.html"
  end

  def iframe_url(space_hash, embed_hash) when is_binary(space_hash) and is_binary(embed_hash) do
    "#{space_origin(space_hash)}/#{embed_hash}/player.html"
  end

  @spec storage_object_url(String.t(), String.t()) :: String.t() | nil
  def storage_object_url(bucket, key) when is_binary(bucket) and is_binary(key) do
    trimmed_bucket = String.trim(bucket)
    trimmed_key = String.trim_leading(key, "/")

    if trimmed_bucket == "" or trimmed_key == "" do
      nil
    else
      bucket = bucket_for_public_url(trimmed_bucket)
      "#{storage_bucket_origin(bucket)}/#{trimmed_key}"
    end
  end

  def storage_object_url(_bucket, _key), do: nil

  @spec player_attributes(EmbedSettings.t() | map() | Embed.t() | nil) :: [
          {String.t(), String.t()}
        ]
  def player_attributes(settings_like) do
    settings = settings_struct(settings_like)

    []
    |> maybe_put("controls", controls_value(settings))
    |> maybe_put("aspect-ratio", player_aspect_ratio(settings))
    |> maybe_put("width", width_value(settings))
    |> maybe_put("height", height_value(settings))
    |> maybe_put("color", color_value(settings))
    |> maybe_put("opacity", opacity_value(settings))
    |> maybe_put("autoplay", autoplay_value(settings))
    |> maybe_put("poster", poster_attr_value(settings))
    |> maybe_put("loop", loop_value(settings))
  end

  @spec attributes_to_string([{String.t(), String.t()}]) :: String.t()
  def attributes_to_string(attributes) when is_list(attributes) do
    attributes
    |> Enum.map_join(" ", fn {key, value} ->
      if key == value do
        key
      else
        ~s(#{key}="#{escape_attribute(value)}")
      end
    end)
  end

  @doc false
  def escape_attribute(value) do
    value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end

  @spec iframe_dimensions(EmbedSettings.t() | map() | Embed.t() | nil) :: %{
          width: String.t(),
          height: String.t()
        }
  def iframe_dimensions(settings_like) do
    settings = settings_struct(settings_like)

    if settings.aspect_ratio_enabled do
      %{width: "640", height: "360"}
    else
      %{
        width: normalize_dimension(settings.width, "640"),
        height: normalize_dimension(settings.height, "360")
      }
    end
  end

  @spec preview_poster_url(Space.t(), Embed.t(), EmbedSettings.t() | map() | nil) ::
          String.t() | nil
  def preview_poster_url(%Space{} = space, %Embed{} = embed, settings_like) do
    settings = settings_struct(settings_like)

    cond do
      uploaded_poster?(settings) ->
        upload_url(settings.external_poster)

      timecode_poster?(settings) ->
        default_poster_url(space, embed, settings.poster_time_seconds)

      true ->
        default_poster_url(space, embed, 0)
    end
  end

  @spec manifest_settings(EmbedSettings.t() | map() | Embed.t() | nil) :: map()
  def manifest_settings(settings_like) do
    settings = settings_struct(settings_like)

    %{
      "aspect_ratio" => manifest_aspect_ratio(settings),
      "width" => manifest_width_value(settings),
      "height" => manifest_height_value(settings),
      "loop" => loop_manifest_value(settings),
      "autoplay" => autoplay_manifest_value(settings),
      "color" => color_value(settings),
      "opacity" => opacity_manifest_value(settings),
      "controls" => controls_manifest_value(settings),
      "poster" => manifest_poster_value(settings)
    }
  end

  @spec manifest_poster(Space.t(), Embed.t(), EmbedSettings.t() | map() | nil, map() | nil) ::
          map()
  def manifest_poster(%Space{} = space, %Embed{} = embed, settings_like, current_poster \\ nil) do
    settings = settings_struct(settings_like)
    current_poster = current_poster || %{}

    cond do
      uploaded_poster?(settings) ->
        url = upload_url(settings.external_poster)

        %{
          "image_src" => url,
          "initial_frame_src" => url,
          "renditions" => Map.get(current_poster, "renditions", []),
          "type" => Map.get(current_poster, "type"),
          "video_src" => Map.get(current_poster, "video_src")
        }

      timecode_poster?(settings) ->
        image_src = default_poster_url(space, embed, settings.poster_time_seconds)

        %{
          "image_src" => image_src,
          "initial_frame_src" => image_src,
          "renditions" => Map.get(current_poster, "renditions", []),
          "type" => Map.get(current_poster, "type"),
          "video_src" => Map.get(current_poster, "video_src")
        }

      true ->
        image_src = poster_image_base_url(space, embed)

        %{
          "image_src" => image_src,
          "initial_frame_src" => poster_image_url(space, embed, 0),
          "renditions" => Map.get(current_poster, "renditions", []),
          "type" => Map.get(current_poster, "type"),
          "video_src" => Map.get(current_poster, "video_src")
        }
    end
  end

  @spec video_aspect_ratio(Video.t() | nil) :: String.t()
  def video_aspect_ratio(%Video{aspect_ratio: ratio}) when is_binary(ratio) and ratio != "" do
    ratio
    |> String.replace(":", " / ")
    |> String.replace("/", " / ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def video_aspect_ratio(%Video{max_width: width, max_height: height})
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    "#{width} / #{height}"
  end

  def video_aspect_ratio(_), do: "16 / 9"

  defp put_time_parts(%EmbedSettings{} = settings) do
    seconds = settings.poster_time_seconds || 0.0
    hours = trunc(seconds / 3600)
    minutes = trunc(seconds / 60) |> rem(60)
    remainder = seconds - hours * 3600 - minutes * 60
    seconds_part = normalize_seconds_part(remainder)

    %{
      settings
      | poster_time_hour: hours,
        poster_time_minute: minutes,
        poster_time_second: seconds_part
    }
  end

  defp normalize_seconds_part(seconds) when is_float(seconds) do
    rounded = Float.round(seconds, 2)

    if rounded == Float.floor(rounded) do
      trunc(rounded)
    else
      rounded
    end
  end

  defp normalize_seconds_part(seconds), do: seconds

  defp controls_value(%EmbedSettings{controls_enabled: false}), do: "none"
  defp controls_value(%EmbedSettings{controls: :big}), do: "big"
  defp controls_value(%EmbedSettings{controls: :none}), do: "none"
  defp controls_value(_settings), do: nil

  defp controls_manifest_value(%EmbedSettings{controls_enabled: false}), do: "none"
  defp controls_manifest_value(%EmbedSettings{controls: :big}), do: "big"
  defp controls_manifest_value(%EmbedSettings{controls: :none}), do: "none"
  defp controls_manifest_value(_settings), do: "full"

  defp player_aspect_ratio(%EmbedSettings{aspect_ratio_enabled: false}), do: nil
  defp player_aspect_ratio(%EmbedSettings{aspect_ratio: :r16_9}), do: nil

  defp player_aspect_ratio(%EmbedSettings{aspect_ratio: ratio}) when is_atom(ratio) do
    ratio
    |> Atom.to_string()
    |> String.replace_prefix("r", "")
    |> String.replace("_", "/")
  end

  defp player_aspect_ratio(_settings), do: nil

  defp manifest_aspect_ratio(%EmbedSettings{aspect_ratio_enabled: false}), do: nil
  defp manifest_aspect_ratio(%EmbedSettings{aspect_ratio: :auto}), do: "auto"
  defp manifest_aspect_ratio(%EmbedSettings{aspect_ratio: :r1_1}), do: "1 / 1"
  defp manifest_aspect_ratio(%EmbedSettings{aspect_ratio: :r4_3}), do: "4 / 3"
  defp manifest_aspect_ratio(_settings), do: "16 / 9"

  defp manifest_width_value(%EmbedSettings{aspect_ratio_enabled: true}), do: nil

  defp manifest_width_value(%EmbedSettings{width: width}) when is_binary(width) and width != "",
    do: normalize_css_dimension(width)

  defp manifest_width_value(_settings), do: nil

  defp manifest_height_value(%EmbedSettings{aspect_ratio_enabled: true}), do: nil

  defp manifest_height_value(%EmbedSettings{height: height})
       when is_binary(height) and height != "", do: normalize_css_dimension(height)

  defp manifest_height_value(_settings), do: nil

  defp width_value(%EmbedSettings{aspect_ratio_enabled: true}), do: nil
  defp width_value(%EmbedSettings{width: width}) when is_binary(width) and width != "", do: width
  defp width_value(_settings), do: "100%"

  defp height_value(%EmbedSettings{aspect_ratio_enabled: true}), do: nil

  defp height_value(%EmbedSettings{height: height}) when is_binary(height) and height != "",
    do: height

  defp height_value(_settings), do: "100%"

  defp color_value(%EmbedSettings{color: color}) when is_binary(color) and color != "" do
    "##{String.trim_leading(color, "#")}"
  end

  defp color_value(_settings), do: nil

  defp opacity_value(%EmbedSettings{color: color, opacity: opacity})
       when is_binary(color) and color != "" and is_integer(opacity) and opacity != 100 do
    Integer.to_string(opacity)
  end

  defp opacity_value(_settings), do: nil

  defp opacity_manifest_value(%EmbedSettings{color: color, opacity: opacity})
       when is_binary(color) and color != "" and is_integer(opacity) and opacity != 100 do
    opacity
  end

  defp opacity_manifest_value(_settings), do: nil

  defp autoplay_value(%EmbedSettings{autoplay_enabled: true, autoplay: :always}), do: "always"
  defp autoplay_value(%EmbedSettings{autoplay_enabled: true, autoplay: :on_show}), do: "lazy"
  defp autoplay_value(_settings), do: nil

  defp autoplay_manifest_value(%EmbedSettings{autoplay_enabled: true, autoplay: :always}),
    do: "always"

  defp autoplay_manifest_value(%EmbedSettings{autoplay_enabled: true, autoplay: :on_show}),
    do: "on_show"

  defp autoplay_manifest_value(_settings), do: nil

  defp poster_attr_value(%EmbedSettings{} = settings) do
    if timecode_poster?(settings) do
      settings.poster_time_seconds
      |> Float.round(2)
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  defp manifest_poster_value(%EmbedSettings{} = settings) do
    cond do
      uploaded_poster?(settings) ->
        "custom"

      settings.poster == :timecode and is_number(settings.poster_time_seconds) and
          settings.poster_time_seconds > 1 ->
        settings.poster_time_seconds

      true ->
        nil
    end
  end

  defp loop_value(%EmbedSettings{loop_enabled: true}), do: "loop"
  defp loop_value(_settings), do: nil

  defp loop_manifest_value(%EmbedSettings{loop_enabled: true}), do: true
  defp loop_manifest_value(_settings), do: nil

  defp normalize_dimension(value, _fallback) when is_binary(value) and value != "" do
    if String.ends_with?(value, "px") do
      String.trim_trailing(value, "px")
    else
      value
    end
  end

  defp normalize_dimension(_, fallback), do: fallback

  defp default_string(value, _fallback) when is_binary(value) and value != "", do: value
  defp default_string(_value, fallback), do: fallback

  defp default_value(nil, fallback), do: fallback
  defp default_value(value, _fallback), do: value

  defp normalize_css_dimension(value) when is_binary(value) and value != "" do
    if String.ends_with?(value, "px") or String.ends_with?(value, "%") do
      value
    else
      "#{value}px"
    end
  end

  defp normalize_css_dimension(_value), do: nil

  defp uploaded_poster?(%EmbedSettings{poster: :upload, external_poster: key})
       when is_binary(key) and key != "" do
    true
  end

  defp uploaded_poster?(_settings), do: false

  defp timecode_poster?(%EmbedSettings{poster: :timecode, poster_time_seconds: seconds})
       when is_number(seconds) and seconds > 0 do
    true
  end

  defp timecode_poster?(_settings), do: false

  defp upload_url(url) when is_binary(url) do
    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      url
    else
      build_upload_url(url)
    end
  end

  defp upload_url(_), do: nil

  defp build_upload_url(key) when is_binary(key) and key != "" do
    upload_config = Application.get_env(:mave_core, :upload, [])
    trimmed_key = String.trim_leading(key, "/")
    upload_public_url(upload_config, trimmed_key)
  end

  defp build_upload_url(_), do: nil

  defp upload_public_url(upload_config, key) do
    case Keyword.get(upload_config, :public_base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        "#{String.trim_trailing(base_url, "/")}/#{key}"

      _ ->
        base_url =
          upload_config
          |> Keyword.get(:source_base_url, "http://localhost:9000")
          |> String.trim_trailing("/")

        bucket = Keyword.get(upload_config, :source_bucket, @upload_bucket)
        "#{base_url}/#{bucket}/#{key}"
    end
  end

  defp default_poster_url(%Space{} = space, %Embed{} = embed, seconds) do
    poster_image_url(space, embed, seconds)
  end

  defp image_base_url do
    :mave_core
    |> Application.get_env(:image_base_url, "https://image.mave.io")
    |> String.trim_trailing("/")
  end

  defp component_base_url do
    case Application.get_env(:mave_core, :components_base_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/")

      _ ->
        configured_component_src_base_url() || "https://cdn.video-dns.com/npm/@maveio/components"
    end
  end

  defp explicit_component_base_url? do
    case Application.get_env(:mave_core, :components_base_url) do
      base when is_binary(base) and base != "" -> true
      _ -> false
    end
  end

  defp infer_component_base_url(src) when is_binary(src) do
    src
    |> String.replace_suffix("/+esm", "")
    |> String.replace_suffix("+esm", "")
    |> String.replace_suffix("/dist/index.js", "")
    |> String.replace_suffix("dist/index.js", "")
    |> String.trim_trailing("/")
  end

  defp configured_component_src_base_url do
    case Application.get_env(:mave_core, :components_src) do
      src when is_binary(src) and src != "" -> infer_component_base_url(src)
      _ -> nil
    end
  end

  defp default_component_src, do: "https://cdn.video-dns.com/npm/@maveio/components/+esm"

  defp default_component_runtime_config?(%{"cdn" => %{"endpoint" => cdn_endpoint}} = config)
       when cdn_endpoint in @default_component_cdn_endpoint_aliases do
    default = default_component_runtime_config()

    put_in(config, ["cdn", "endpoint"], default["cdn"]["endpoint"]) == default
  end

  defp default_component_runtime_config?(_config), do: false

  defp application_origin do
    case Application.get_env(:mave_core, :domain) do
      domain when is_binary(domain) and domain != "" ->
        String.trim_trailing(domain, "/")

      _ ->
        MaveCoreWeb.Endpoint.url()
        |> String.trim_trailing("/")
    end
  end

  defp upload_endpoint do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(:endpoint, "http://localhost:1080/files")
    |> String.trim()
  end

  defp upload_source_base_url do
    :mave_core
    |> Application.get_env(:upload, [])
    |> Keyword.get(:source_base_url, "http://localhost:9000")
    |> String.trim()
  end

  defp upload_socket_endpoint do
    "#{socket_origin()}/api/v1/socket"
  end

  defp metrics_endpoint do
    case first_host_from_env("MAVE_METRICS_HOST") do
      nil -> "#{application_origin()}/v1/events"
      host -> "#{application_scheme()}://#{host}/v1/events"
    end
  end

  defp api_endpoint do
    case first_host_from_env("MAVE_API_HOST") do
      nil -> "#{application_origin()}/api/v1"
      host -> "#{application_scheme()}://#{host}/api/v1"
    end
  end

  defp cdn_component_endpoint do
    case public_cdn_base_url() do
      base_url when is_binary(base_url) ->
        "#{base_url}/space-${this.spaceId}"

      nil ->
        case public_cdn_mode() do
          :direct_s3 -> direct_s3_component_endpoint()
          :path -> "#{cdn_scheme()}://cdn.#{cdn_host()}/space-${this.spaceId}"
          :subdomain -> "#{cdn_scheme()}://space-${this.spaceId}.#{cdn_host()}"
        end
    end
  end

  defp storage_bucket_origin(bucket) when is_binary(bucket) do
    case public_cdn_base_url() do
      base_url when is_binary(base_url) ->
        "#{base_url}/#{bucket}"

      nil ->
        case public_cdn_mode() do
          :direct_s3 -> direct_s3_bucket_origin(bucket)
          :path -> "#{cdn_scheme()}://cdn.#{cdn_host()}/#{bucket}"
          :subdomain -> "#{cdn_scheme()}://#{bucket}.#{cdn_host()}"
        end
    end
  end

  defp bucket_for_public_url(bucket) do
    if public_cdn_mode() == :direct_s3, do: bucket, else: Storage.public_bucket_name(bucket)
  end

  defp direct_s3_component_endpoint do
    case URI.parse(upload_source_base_url()) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://space-${this.spaceId}.#{host}"

      _ ->
        "#{cdn_scheme()}://space-${this.spaceId}.#{cdn_host()}"
    end
  end

  defp direct_s3_bucket_origin(bucket) do
    case URI.parse(upload_source_base_url()) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{bucket}.#{host}"

      _ ->
        "#{cdn_scheme()}://#{bucket}.#{cdn_host()}"
    end
  end

  defp socket_origin do
    application_origin()
    |> String.replace_prefix("https://", "wss://")
    |> String.replace_prefix("http://", "ws://")
  end

  defp application_scheme do
    application_origin()
    |> URI.parse()
    |> Map.get(:scheme, "https")
  end

  defp first_host_from_env(env_var) do
    env_var
    |> System.get_env()
    |> case do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.find(&(&1 != ""))
    end
  end

  defp space_origin(space_hash) when is_binary(space_hash) do
    case public_cdn_base_url() do
      base_url when is_binary(base_url) ->
        "#{base_url}/space-#{space_hash}"

      nil ->
        case public_cdn_mode() do
          :direct_s3 -> direct_s3_bucket_origin("space-#{space_hash}")
          :path -> "#{cdn_scheme()}://cdn.#{cdn_host()}/space-#{space_hash}"
          :subdomain -> "#{cdn_scheme()}://space-#{space_hash}.#{cdn_host()}"
        end
    end
  end

  defp public_cdn_base_url do
    case Application.get_env(:mave_core, :public_cdn_base_url) do
      base_url when is_binary(base_url) and base_url != "" -> String.trim_trailing(base_url, "/")
      _other -> nil
    end
  end

  defp cdn_scheme do
    Application.get_env(:mave_core, :public_cdn_scheme, "https")
  end

  defp cdn_host do
    Application.get_env(:mave_core, :public_cdn_host, "video-dns.com")
  end

  defp public_cdn_mode do
    case Application.get_env(:mave_core, :public_cdn_mode) do
      mode when mode in [:path, :subdomain, :direct_s3] ->
        mode

      "path" ->
        :path

      "subdomain" ->
        :subdomain

      "direct_s3" ->
        :direct_s3

      _ ->
        infer_public_cdn_mode(cdn_host())
    end
  end

  defp infer_public_cdn_mode("staging.video-dns.com"), do: :direct_s3
  defp infer_public_cdn_mode("saas.orb.local"), do: :path
  defp infer_public_cdn_mode(_), do: :subdomain

  defp normalize_time(seconds) when is_integer(seconds), do: Integer.to_string(seconds)

  defp normalize_time(seconds) when is_float(seconds) do
    seconds
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp normalize_time(_seconds), do: "0"

  defp maybe_put(attributes, _key, nil), do: attributes
  defp maybe_put(attributes, key, value), do: attributes ++ [{key, value}]
end
