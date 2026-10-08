defmodule MaveCore.Media.ContentType do
  @moduledoc false

  @media_types ~w(
    video/mp4 video/webm video/quicktime video/x-matroska video/x-msvideo video/mpeg
    video/mp2t video/ogg video/x-flv video/x-m4v video/x-ms-wmv video/3gpp video/3gpp2
    audio/mpeg audio/mp3 audio/mp4 audio/x-m4a audio/aac audio/aacp audio/ogg audio/opus
    audio/flac audio/x-flac audio/wav audio/wave audio/x-wav audio/vnd.wave audio/webm
    audio/aiff audio/x-aiff audio/amr audio/3gpp application/ogg application/octet-stream
  )

  def media(value) when is_binary(value) do
    type = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    if type in @media_types, do: type, else: "application/octet-stream"
  end

  def media(_value), do: "application/octet-stream"
end
