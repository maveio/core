defmodule MaveCore.Flow.RetryPolicy do
  @moduledoc false

  alias MaveCore.EncodingBooster

  def capacity_error?(:encoding_booster_busy), do: true

  def capacity_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&capacity_error?/1)
  end

  def capacity_error?(reason) when is_list(reason), do: Enum.any?(reason, &capacity_error?/1)
  def capacity_error?(_reason), do: false

  def resumable_chunk_error?(
        {:media_transcode_h264_ladder_failed, {:encoding_booster_chunk_failed, index, _reason}}
      )
      when is_integer(index) and index >= 0,
      do: true

  def resumable_chunk_error?(_reason), do: false

  def booster_gateway_error?({:encoding_booster_http_status, 502}), do: true

  def booster_gateway_error?(
        {:encoding_booster_request_failed, %Req.TransportError{reason: :closed}}
      ),
      do: true

  def booster_gateway_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&booster_gateway_error?/1)
  end

  def booster_gateway_error?(reason) when is_list(reason),
    do: Enum.any?(reason, &booster_gateway_error?/1)

  def booster_gateway_error?(_reason), do: false

  def transient_error?(reason) do
    booster_gateway_error?(reason) or transient_error_reason?(reason)
  end

  defp transient_error_reason?({:flame_execution_failed, _step_type, _message}), do: true

  defp transient_error_reason?({:flame_execution_failed, _step_type, _kind, _reason}),
    do: true

  defp transient_error_reason?({:media_transcode_h264_ladder_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?({:media_transcode_video_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?({:media_transcode_audio_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?({:media_extract_frame_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?({:media_package_hls_audio_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?({:original_upload_failed, reason}),
    do: media_transport_error?(reason)

  defp transient_error_reason?(reason), do: request_transport_error?(reason)

  defp media_transport_error?(reason) do
    EncodingBooster.transient_error?(reason) or request_transport_error?(reason)
  end

  defp request_transport_error?(%Req.TransportError{}), do: true

  defp request_transport_error?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&request_transport_error?/1)
  end

  defp request_transport_error?(reason) when is_list(reason),
    do: Enum.any?(reason, &request_transport_error?/1)

  defp request_transport_error?(_reason), do: false
end
