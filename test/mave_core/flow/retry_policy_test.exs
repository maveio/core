defmodule MaveCore.Flow.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias MaveCore.Flow.RetryPolicy

  test "classifies only nested booster busy responses as capacity errors" do
    assert RetryPolicy.capacity_error?(
             {:media_transcode_h264_ladder_failed, :encoding_booster_busy}
           )

    refute RetryPolicy.capacity_error?(
             {:media_transcode_h264_ladder_failed,
              {:encoding_booster_request_failed, %Req.TransportError{reason: :closed}}}
           )
  end

  test "identifies only H264 ladder chunk failures as resumable" do
    assert RetryPolicy.resumable_chunk_error?(
             {:media_transcode_h264_ladder_failed,
              {:encoding_booster_chunk_failed, 8, :encoding_booster_request_failed}}
           )

    refute RetryPolicy.resumable_chunk_error?(
             {:media_transcode_video_failed,
              {:encoding_booster_chunk_failed, 8, :encoding_booster_request_failed}}
           )

    refute RetryPolicy.resumable_chunk_error?(
             {:media_transcode_h264_ladder_failed, :encoding_booster_request_failed}
           )
  end

  test "identifies retryable booster gateway disconnects" do
    assert RetryPolicy.booster_gateway_error?(
             {:media_transcode_video_failed, {:encoding_booster_http_status, 502}}
           )

    assert RetryPolicy.booster_gateway_error?(
             {:media_transcode_h264_ladder_failed,
              {:encoding_booster_request_failed, %Req.TransportError{reason: :closed}}}
           )

    refute RetryPolicy.booster_gateway_error?(
             {:media_transcode_video_failed,
              {:encoding_booster_http_status, 502, "source returned HTTP 403"}}
           )

    refute RetryPolicy.booster_gateway_error?(
             {:media_transcode_video_failed, {:encoding_booster_http_status, 503}}
           )

    refute RetryPolicy.booster_gateway_error?(
             {:media_transcode_video_failed,
              {:encoding_booster_request_failed, %Req.TransportError{reason: :timeout}}}
           )
  end

  test "classifies nested request timeouts as transient" do
    error =
      {:media_package_hls_audio_failed,
       {:hls_upload_failed, "segment_034.m4s", %Req.TransportError{reason: :timeout}}}

    assert RetryPolicy.transient_error?(error)
  end

  test "classifies status-only booster 502 responses consistently across step wrappers" do
    for wrapper <- [
          :media_transcode_waveform_failed,
          :media_generate_segments_failed,
          :media_generate_storyboard_failed,
          :media_package_hls_variant_failed
        ] do
      assert RetryPolicy.transient_error?({wrapper, {:encoding_booster_http_status, 502}})
    end

    refute RetryPolicy.transient_error?(
             {:media_generate_storyboard_failed,
              {:encoding_booster_http_status, 502, "source returned HTTP 403"}}
           )
  end

  test "classifies nested closed request transports as transient" do
    error =
      {:media_package_hls_audio_failed,
       {:hls_upload_failed, "segment_034.m4s", %Req.TransportError{reason: :closed}}}

    assert RetryPolicy.transient_error?(error)
  end

  test "keeps deterministic packaging failures terminal" do
    refute RetryPolicy.transient_error?(
             {:media_package_hls_audio_failed,
              {:hls_upload_failed, "segment_034.m4s", :permission_denied}}
           )
  end

  test "keeps exhausted object verification failures out of full step retries" do
    refute RetryPolicy.transient_error?(
             {:media_transcode_h264_ladder_failed,
              {:rendition_upload_verification_failed, "fhd", {:object_info_failed, 403}}}
           )
  end

  test "delegates booster transport failures to the booster retry policy" do
    assert RetryPolicy.transient_error?(
             {:media_transcode_h264_ladder_failed, :encoding_booster_busy}
           )

    assert RetryPolicy.transient_error?(
             {:media_transcode_video_failed,
              {:encoding_booster_request_failed, %Req.TransportError{reason: :timeout}}}
           )

    assert RetryPolicy.transient_error?(
             {:media_transcode_h264_ladder_failed, :encoding_booster_request_failed}
           )

    assert RetryPolicy.transient_error?(
             {:media_extract_frame_failed, :encoding_booster_request_failed}
           )
  end

  test "keeps deterministic booster request errors terminal" do
    refute RetryPolicy.transient_error?(
             {:media_transcode_h264_ladder_failed,
              {:encoding_booster_http_status, 400, "unknown request field"}}
           )

    refute RetryPolicy.transient_error?(
             {:original_upload_failed,
              {:encoding_booster_http_status, 502, "source returned HTTP 403"}}
           )

    refute RetryPolicy.transient_error?(
             {:media_extract_frame_failed,
              {:encoding_booster_http_status, 500,
               "ffmpeg could not start the stream: Error opening input: Server returned 404"}}
           )
  end
end
