defmodule MaveCore.EncodingBoosterTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias MaveCore.EncodingBooster
  alias MaveCore.EncodingBooster.Concat
  alias MaveCore.EncodingBooster.Faststart

  defmodule FaststartAdapterStub do
    @moduledoc false

    def remux(path) do
      with {:ok, body} <- File.read(path),
           remuxed = "faststart:" <> body,
           :ok <- File.write(path, remuxed) do
        {:ok, %{size_bytes: byte_size(remuxed)}}
      end
    end
  end

  defmodule FailingFaststartAdapterStub do
    @moduledoc false

    def remux(_path), do: {:error, {:encoding_booster_remux_failed, 1}}
  end

  defmodule GpuScalerStub do
    @moduledoc false

    def prewarm do
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), :gpu_scale_requested)
      :ok
    end
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_req_options = Req.default_options()
    old_config = Application.get_env(:mave_core, :encoding_booster)

    old_faststart_adapter =
      Application.get_env(:mave_core, :encoding_booster_faststart_adapter)

    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)
    old_gpu_config = Application.get_env(:mave_core, :gpu_encoding_booster)
    old_gpu_scaler = Application.get_env(:mave_core, :gpu_encoding_booster_scaler_adapter)
    old_test_pid = Application.get_env(:mave_core, :encoding_booster_test_pid)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Application.put_env(
      :mave_core,
      :encoding_booster_faststart_adapter,
      FaststartAdapterStub
    )

    Application.put_env(:mave_core, :encoding_booster_test_pid, self())

    output_path =
      Path.join(
        System.tmp_dir!(),
        "encoding_booster_#{System.unique_integer([:positive])}.mp4"
      )

    on_exit(fn ->
      Req.default_options(previous_req_options)
      restore_env(:encoding_booster, old_config)
      restore_env(:encoding_booster_faststart_adapter, old_faststart_adapter)
      restore_env(:public_http_url_resolver, old_resolver)
      restore_env(:gpu_encoding_booster, old_gpu_config)
      restore_env(:gpu_encoding_booster_scaler_adapter, old_gpu_scaler)
      restore_env(:encoding_booster_test_pid, old_test_pid)
      File.rm(output_path)
    end)

    %{output_path: output_path}
  end

  test "returns bounded audio peak metadata without media remuxing", %{output_path: path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})
    body = "lavfi.astats.Overall.Peak_level=-20.000000\n"

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "accept") == ["text/plain"]
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["operation"] == "audio_peaks"
      assert payload["duration_seconds"] == 2.0
      send_resp(conn, 200, body)
    end)

    assert {:ok, %{size_bytes: size}} =
             EncodingBooster.encode_to_file(
               "https://source.example/audio.mp3",
               path,
               operation: "audio_peaks",
               duration_seconds: 2.0
             )

    assert size == byte_size(body)
    assert File.read!(path) == body
  end

  test "rejects oversized audio peak metadata", %{output_path: path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.expect(__MODULE__, &send_resp(&1, 200, String.duplicate("x", 65_537)))

    assert {:error, :invalid_audio_peaks_response} =
             EncodingBooster.encode_to_file(
               "https://source.example/audio.mp3",
               path,
               operation: "audio_peaks",
               duration_seconds: 2.0
             )

    refute File.exists?(path)
  end

  test "is disabled by default", %{output_path: output_path} do
    Application.put_env(:mave_core, :encoding_booster, enabled: false)

    assert {:error, :encoding_booster_disabled} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               width: 1280
             )

    refute File.exists?(output_path)
  end

  test "is enabled globally when configured" do
    Application.put_env(:mave_core, :encoding_booster, enabled: true)

    assert EncodingBooster.enabled?()

    Application.put_env(:mave_core, :encoding_booster, enabled: false)
    refute EncodingBooster.enabled?()
  end

  test "classifies only capacity and transport booster failures as transient" do
    assert EncodingBooster.transient_error?(:encoding_booster_busy)
    assert EncodingBooster.transient_error?({:encoding_booster_not_ready, 503})
    assert EncodingBooster.transient_error?({:encoding_booster_http_status, 500})
    assert EncodingBooster.transient_error?({:encoding_booster_http_status, 503, "draining"})
    assert EncodingBooster.transient_error?(:incomplete_encoding_booster_bundle)

    assert EncodingBooster.transient_error?(
             {:encoding_booster_chunk_failed, 2, {:encoding_booster_http_status, 503}}
           )

    refute EncodingBooster.transient_error?({:encoding_booster_http_status, 400})
    refute EncodingBooster.transient_error?({:encoding_booster_http_status, 400, "invalid width"})

    refute EncodingBooster.transient_error?(
             {:encoding_booster_http_status, 502, "source returned HTTP 403"}
           )

    refute EncodingBooster.transient_error?(
             {:encoding_booster_http_status, 500,
              "ffmpeg could not start the stream: Error opening input: Server returned 404"}
           )

    refute EncodingBooster.transient_error?(
             {:encoding_booster_remote_failed, "source returned HTTP 410"}
           )

    refute EncodingBooster.transient_error?({:encoding_booster_remux_failed, 1})
    refute EncodingBooster.transient_error?(:invalid_encoding_booster_request)
  end

  test "sends a bounded source interval for a chunked encode", %{output_path: output_path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["start_seconds"] == 1_800.0
      assert payload["duration_seconds"] == 900.5
      send_resp(conn, 200, "encoded-chunk")
    end)

    assert {:ok, %{size_bytes: size_bytes}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               start_seconds: 1_800.0,
               duration_seconds: 900.5
             )

    assert size_bytes > 0
  end

  test "streams an encode response to a file and sends the encoding contract", %{
    output_path: output_path
  } do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})
    owner = self()

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/encode"
      assert get_req_header(conn, "x-auth-token") == ["secret-key"]
      assert get_req_header(conn, "accept") == ["video/mp4"]

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert payload == %{
               "input_url" => "https://source.example/video.mp4",
               "input_referer" => "https://ffmpeg.storage.mave.invalid/test-token",
               "encoding_profile" => "mave-production-v2",
               "width" => 1280,
               "video_bitrate" => 2_500_000,
               "video_crf" => 23,
               "audio_bitrate" => "128k",
               "preset" => "veryfast",
               "tune" => "grain",
               "include_audio" => true,
               "keyframe_interval_seconds" => 2
             }

      conn
      |> put_resp_header("x-mave-booster-instance", "instance-a")
      |> put_resp_header("x-mave-ffmpeg-elapsed-ms", "9123")
      |> put_resp_header("x-mave-ffmpeg-frames", "1500")
      |> put_resp_header("x-mave-ffmpeg-fps", "164.52")
      |> put_resp_header("x-mave-ffmpeg-speed", "5.48x")
      |> put_resp_header("x-mave-ffmpeg-out-time-ms", "50000")
      |> put_resp_header("x-mave-ffmpeg-output-bytes", "11")
      |> put_resp_header("x-mave-ffmpeg-dup-frames", "2")
      |> put_resp_header("x-mave-ffmpeg-drop-frames", "1")
      |> send_resp(200, "encoded-mp4")
    end)

    assert {:ok,
            %{
              elapsed_ms: elapsed_ms,
              size_bytes: 21,
              instance_id: "instance-a",
              ffmpeg_elapsed_ms: 9_123,
              frames: 1_500,
              fps: 164.52,
              speed_x: 5.48,
              out_time_ms: 50_000,
              output_bytes: 11,
              dup_frames: 2,
              drop_frames: 1
            }} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               input_referer: "https://ffmpeg.storage.mave.invalid/test-token",
               encoding_profile: "mave-production-v2",
               codec: "h264",
               width: 1280,
               video_bitrate: 2_500_000,
               video_crf: 23,
               audio_bitrate: "128k",
               preset: "veryfast",
               tune: "grain",
               include_audio: true,
               keyframe_interval_seconds: 2,
               on_chunk: fn total_bytes -> send(owner, {:booster_bytes, total_bytes}) end
             )

    assert elapsed_ms >= 0
    assert File.read!(output_path) == "faststart:encoded-mp4"
    assert_received {:booster_bytes, 11}
  end

  test "does not send the private storage Referer with a presigned input", %{
    output_path: output_path
  } do
    old_s3 = Application.get_env(:mave_core, :s3)

    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://storage.example",
      region: "fr-par"
    )

    on_exit(fn -> restore_env(:s3, old_s3) end)

    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      refute Map.has_key?(payload, "input_referer")
      send_resp(conn, 200, "encoded-mp4")
    end)

    assert {:ok, %{size_bytes: 21}} =
             EncodingBooster.encode_to_file(
               "https://storage.example/space-demo/video.mp4?X-Amz-Signature=abc123",
               output_path,
               input_referer: "https://ffmpeg.storage.mave.invalid/private-token"
             )
  end

  test "sends URL Basic auth to the private encoder", %{output_path: output_path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert payload["input_url"] ==
               "https://video%40example.com:p%40ssword@source.example/video.mp4"

      send_resp(conn, 200, "encoded-mp4")
    end)

    assert {:ok, %{size_bytes: 21}} =
             EncodingBooster.encode_to_file(
               "https://video%40example.com:p%40ssword@source.example/video.mp4",
               output_path
             )
  end

  test "streams progress while the booster writes directly to object storage" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})
    owner = self()

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/encode"
      assert get_req_header(conn, "accept") == ["application/x-ndjson"]

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["input_url"] == "https://source.example/video.mp4"
      assert payload["output_upload"] == output_upload
      assert payload["width"] == 1280

      body =
        [
          Jason.encode!(%{"status" => "uploading", "uploaded_bytes" => 128}),
          Jason.encode!(%{
            "status" => "completed",
            "uploaded_bytes" => 256,
            "size_bytes" => 256,
            "metrics" => %{"frame" => "120", "fps" => "48.5", "speed" => "2.0x"}
          })
        ]
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      conn
      |> put_resp_header("x-mave-booster-instance", "instance-direct")
      |> send_resp(200, body)
    end)

    assert {:ok,
            %{
              size_bytes: 256,
              output_bytes: 256,
              frames: 120,
              fps: 48.5,
              speed_x: 2.0,
              instance_id: "instance-direct"
            }} =
             EncodingBooster.encode_to_storage(
               "https://source.example/video.mp4",
               output_upload,
               width: 1280,
               on_chunk: fn bytes -> send(owner, {:direct_upload_bytes, bytes}) end
             )

    assert_received {:direct_upload_bytes, 128}
    assert_received {:direct_upload_bytes, 256}
  end

  test "sends bounded audio and frame operations to the direct-storage encoder" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    Req.Test.expect(__MODULE__, 2, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["output_upload"] == output_upload

      case payload["operation"] do
        "audio" ->
          assert payload["audio_codec"] == "mp3"
          assert payload["audio_stream_index"] == 1

        "frame" ->
          assert payload["frame_role"] == "thumbnail"
          assert payload["frame_codec"] == "jpg"
      end

      send_resp(
        conn,
        200,
        Jason.encode!(%{"status" => "completed", "size_bytes" => 64}) <> "\n"
      )
    end)

    assert {:ok, %{size_bytes: 64}} =
             EncodingBooster.encode_to_storage(
               "https://source.example/video.mp4",
               output_upload,
               operation: "audio",
               audio_codec: "mp3",
               audio_stream_index: 1,
               audio_bitrate: "128k"
             )

    assert {:ok, %{size_bytes: 64}} =
             EncodingBooster.encode_to_storage(
               "https://source.example/video.mp4",
               output_upload,
               operation: "frame",
               frame_role: "thumbnail",
               frame_codec: "jpg"
             )
  end

  test "sends waveform, storyboard, and multi-output segments to direct storage" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    segment_outputs = [
      %{"name" => "thumbnail_0.jpg", "output_upload" => output_upload},
      %{"name" => "thumbnail_1.jpg", "output_upload" => output_upload}
    ]

    Req.Test.expect(__MODULE__, 3, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      case payload["operation"] do
        "waveform" ->
          refute Map.has_key?(payload, "codec")
          assert payload["output_upload"] == output_upload

        "storyboard" ->
          assert payload["frame_codec"] == "jpg"
          assert payload["duration_seconds"] == 60.0
          assert payload["count"] == 10
          assert payload["output_upload"] == output_upload

        "segments" ->
          assert payload["frame_codec"] == "jpg"
          assert payload["duration_seconds"] == 60.0
          assert payload["count"] == 2
          assert payload["output_uploads"] == segment_outputs
      end

      send_resp(
        conn,
        200,
        Jason.encode!(%{"status" => "completed", "size_bytes" => 128}) <> "\n"
      )
    end)

    assert {:ok, %{size_bytes: 128}} =
             EncodingBooster.encode_to_storage(
               "https://source.example/audio.mp3",
               output_upload,
               operation: "waveform",
               codec: "h264"
             )

    assert {:ok, %{size_bytes: 128}} =
             EncodingBooster.encode_to_storage(
               "https://source.example/video.mp4",
               output_upload,
               operation: "storyboard",
               frame_codec: "jpg",
               duration_seconds: 60.0,
               count: 10
             )

    assert {:ok, %{size_bytes: 128}} =
             EncodingBooster.encode_many_to_storage(
               "https://source.example/video.mp4",
               segment_outputs,
               operation: "segments",
               frame_codec: "jpg",
               duration_seconds: 60.0,
               count: 2
             )
  end

  test "requests remote concat without downloading its input chunks" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/concat"

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert payload["input_urls"] == [
               "https://storage.example/chunk-1.mp4",
               "https://storage.example/chunk-2.mp4"
             ]

      assert payload["output_upload"] == output_upload

      send_resp(
        conn,
        200,
        Jason.encode!(%{"status" => "completed", "size_bytes" => 512}) <> "\n"
      )
    end)

    assert {:ok, %{size_bytes: 512}} =
             EncodingBooster.concat_to_storage(
               [
                 "https://storage.example/chunk-1.mp4",
                 "https://storage.example/chunk-2.mp4"
               ],
               output_upload
             )
  end

  test "requests a byte-for-byte remote transfer into object storage" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/transfer"

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["input_url"] == "https://source.example/original.mp4"
      assert payload["input_referer"] == "https://source.example/"
      assert payload["output_upload"] == output_upload

      send_resp(
        conn,
        200,
        Jason.encode!(%{
          "status" => "completed",
          "size_bytes" => 1_024,
          "sha256" => String.duplicate("a", 64)
        }) <> "\n"
      )
    end)

    assert {:ok, %{size_bytes: 1_024, sha256: sha256}} =
             EncodingBooster.transfer_to_storage(
               "https://source.example/original.mp4",
               output_upload,
               input_referer: "https://source.example/"
             )

    assert sha256 == String.duplicate("a", 64)
  end

  test "moves URL Basic auth into the protected remote transfer payload" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    output_upload = %{
      "part_size_bytes" => 134_217_728,
      "part_urls" => ["https://storage.example/part-1"],
      "complete_url" => "https://storage.example/complete",
      "abort_url" => "https://storage.example/abort"
    }

    Req.Test.expect(__MODULE__, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert payload["input_url"] == "https://source.example/original.mp4"
      assert payload["input_basic_auth"] == "video@example.com:p@ssword"
      refute payload["input_url"] =~ "video"

      send_resp(
        conn,
        200,
        Jason.encode!(%{"status" => "completed", "size_bytes" => 1_024}) <> "\n"
      )
    end)

    assert {:ok, %{size_bytes: 1_024}} =
             EncodingBooster.transfer_to_storage(
               "https://video%40example.com:p%40ssword@source.example/original.mp4",
               output_upload
             )
  end

  test "extracts a booster-produced HLS bundle beside the encoded rendition", %{
    output_path: output_path
  } do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert get_req_header(conn, "accept") == [
               "application/vnd.mave.encoding-bundle+zip"
             ]

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["package_hls"] == true

      conn
      |> put_resp_header("content-type", "application/vnd.mave.encoding-bundle+zip")
      |> send_resp(200, encoding_bundle())
    end)

    assert {:ok, %{size_bytes: 21, hls_dir: hls_dir}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               package_hls: true
             )

    assert File.read!(output_path) == "faststart:encoded-mp4"
    assert File.read!(Path.join(hls_dir, "playlist.m3u8")) == "#EXTM3U\n"
    assert File.read!(Path.join(hls_dir, "init.mp4")) == "init"
    assert File.read!(Path.join(hls_dir, "segment_000.m4s")) == "segment"

    File.rm_rf!(output_path <> ".bundle")
  end

  test "extracts the streamed ZIP format produced by the Go booster", %{
    output_path: output_path
  } do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_header("content-type", "application/vnd.mave.encoding-bundle+zip")
      |> send_resp(200, go_streaming_encoding_bundle())
    end)

    assert {:ok, %{size_bytes: 21, hls_dir: hls_dir}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               package_hls: true
             )

    assert File.read!(output_path) == "faststart:encoded-mp4"
    assert File.read!(Path.join(hls_dir, "playlist.m3u8")) == "#EXTM3U\n"
    assert File.read!(Path.join(hls_dir, "init.mp4")) == "init"
    assert File.read!(Path.join(hls_dir, "segment_000.m4s")) == "segment"

    File.rm_rf!(output_path <> ".bundle")
  end

  test "packages an encoded rendition through the HLS-only booster endpoint", %{
    output_path: output_path
  } do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})
    extract_root = output_path <> ".hls"

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/package-hls"
      assert get_req_header(conn, "x-auth-token") == ["secret-key"]
      assert get_req_header(conn, "accept") == ["application/vnd.mave.hls-bundle+zip"]

      assert conn |> Req.Test.raw_body() |> Jason.decode!() == %{
               "input_url" => "https://source.example/encoded.mp4",
               "input_referer" => "https://ffmpeg.storage.mave.invalid/test-token"
             }

      conn
      |> put_resp_header("x-mave-booster-instance", "instance-hls")
      |> put_resp_header("content-type", "application/vnd.mave.hls-bundle+zip")
      |> send_resp(200, hls_bundle())
    end)

    assert {:ok, %{hls_dir: hls_dir, elapsed_ms: elapsed_ms, instance_id: "instance-hls"}} =
             EncodingBooster.package_hls_to_dir(
               "https://source.example/encoded.mp4",
               extract_root,
               input_referer: "https://ffmpeg.storage.mave.invalid/test-token"
             )

    assert elapsed_ms >= 0
    assert File.read!(Path.join(hls_dir, "playlist.m3u8")) == "#EXTM3U\n"
    assert File.read!(Path.join(hls_dir, "init.mp4")) == "init"
    assert File.read!(Path.join(hls_dir, "segment_000.m4s")) == "segment"
    refute File.exists?(extract_root <> ".zip")

    File.rm_rf!(extract_root)
  end

  test "publishes HLS objects directly through the booster endpoint" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/package-hls"
      assert get_req_header(conn, "x-auth-token") == ["secret-key"]
      assert get_req_header(conn, "accept") == ["application/x-ndjson"]

      assert conn |> Req.Test.raw_body() |> Jason.decode!() == %{
               "input_url" => "https://source.example/encoded.mp4",
               "input_referer" => "https://ffmpeg.storage.mave.invalid/test-token",
               "upload_token" => "scoped-upload-token"
             }

      body =
        [
          %{"status" => "uploading", "uploaded_bytes" => 4, "file_count" => 1},
          %{
            "status" => "completed",
            "uploaded_bytes" => 20,
            "file_count" => 3,
            "ffmpeg_elapsed_ms" => 45,
            "files" => [
              %{
                "name" => "init.mp4",
                "key" => "embed/h264_sd_hls/init.mp4",
                "content_type" => "video/mp4",
                "size_bytes" => 4
              },
              %{
                "name" => "playlist.m3u8",
                "key" => "embed/h264_sd_hls/playlist.m3u8",
                "content_type" => "application/vnd.apple.mpegurl",
                "size_bytes" => 8
              },
              %{
                "name" => "segment_000.m4s",
                "key" => "embed/h264_sd_hls/segment_000.m4s",
                "content_type" => "video/mp4",
                "size_bytes" => 8
              }
            ]
          }
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)
        |> Kernel.<>("\n")

      conn
      |> put_resp_header("x-mave-booster-instance", "instance-hls-direct")
      |> put_resp_content_type("application/x-ndjson")
      |> send_resp(200, body)
    end)

    assert {:ok,
            %{
              files: files,
              size_bytes: 20,
              ffmpeg_elapsed_ms: 45,
              instance_id: "instance-hls-direct"
            }} =
             EncodingBooster.package_hls_to_storage(
               "https://source.example/encoded.mp4",
               "scoped-upload-token",
               input_referer: "https://ffmpeg.storage.mave.invalid/test-token"
             )

    assert Enum.map(files, & &1["name"]) == [
             "init.mp4",
             "playlist.m3u8",
             "segment_000.m4s"
           ]
  end

  test "requests direct audio HLS packaging" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      payload = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert payload["media_kind"] == "audio"
      assert payload["channels"] == 2

      body =
        Jason.encode!(%{
          "status" => "completed",
          "uploaded_bytes" => 20,
          "file_count" => 3,
          "ffmpeg_elapsed_ms" => 12,
          "files" => [
            %{
              "name" => "init.mp4",
              "key" => "embed/audio_hls/init.mp4",
              "content_type" => "audio/mp4",
              "size_bytes" => 4
            },
            %{
              "name" => "playlist.m3u8",
              "key" => "embed/audio_hls/playlist.m3u8",
              "content_type" => "application/vnd.apple.mpegurl",
              "size_bytes" => 8
            },
            %{
              "name" => "segment_000.m4s",
              "key" => "embed/audio_hls/segment_000.m4s",
              "content_type" => "audio/mp4",
              "size_bytes" => 8
            }
          ]
        }) <> "\n"

      send_resp(conn, 200, body)
    end)

    assert {:ok, %{ffmpeg_elapsed_ms: 12}} =
             EncodingBooster.package_hls_to_storage(
               "https://source.example/audio.mp3",
               "scoped-upload-token",
               media_kind: "audio",
               channels: 2
             )
  end

  test "preserves a bounded booster validation error", %{output_path: output_path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{"error" => "preset is not allowed"}))
    end)

    assert {:error, {:encoding_booster_http_status, 400, "preset is not allowed"}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               package_hls: true
             )

    refute File.exists?(output_path)
    refute File.exists?(output_path <> ".bundle.zip")
  end

  test "preserves bounded sanitized FFmpeg details from a booster failure", %{
    output_path: output_path
  } do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        500,
        Jason.encode!(%{
          "error" => "ffmpeg could not start the stream",
          "details" => "muxer does not support non seekable output"
        })
      )
    end)

    assert {:error,
            {:encoding_booster_http_status, 500,
             "ffmpeg could not start the stream: muxer does not support non seekable output"}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               package_hls: true
             )
  end

  test "warms the CPU booster through its dedicated scaling endpoint" do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/warmup"
      assert conn.query_string == "hold_ms=15000"
      assert get_req_header(conn, "x-auth-token") == ["secret-key"]
      send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = EncodingBooster.warmup(:cpu)
  end

  test "prewarms parallel CPU capacity for the initial rendition fan-out" do
    configure_booster(warmup_requests: 3, warmup_hold_ms: 12_345)
    Req.default_options(plug: {Req.Test, __MODULE__})
    owner = self()

    Req.Test.expect(__MODULE__, 3, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/warmup"
      assert conn.query_string == "hold_ms=12345"
      send(owner, :cpu_warmup_requested)
      send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = EncodingBooster.warmup_async("ubg50")
    assert_receive :cpu_warmup_requested
    assert_receive :cpu_warmup_requested
    assert_receive :cpu_warmup_requested
  end

  test "CPU encode delegates when prewarmed capacity is not ready", %{
    output_path: output_path
  } do
    configure_booster(readiness_check_enabled: true, readiness_timeout_ms: 1_000)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/health"
      assert get_req_header(conn, "x-auth-token") == ["secret-key"]
      send_resp(conn, 503, ~s({"status":"starting"}))
    end)

    assert {:error, {:encoding_booster_not_ready, 503}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  test "requests the GPU pool before warming the GPU endpoint" do
    Application.put_env(:mave_core, :encoding_booster, enabled: false)

    Application.put_env(:mave_core, :gpu_encoding_booster,
      enabled: true,
      endpoint: "http://10.0.0.20:8080",
      bearer_token: "gpu-secret"
    )

    Application.put_env(:mave_core, :gpu_encoding_booster_scaler_adapter, GpuScalerStub)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/health"
      send(Application.fetch_env!(:mave_core, :encoding_booster_test_pid), :gpu_health_requested)
      send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = EncodingBooster.warmup_async("ubg50")
    assert_receive :gpu_scale_requested
    assert_receive :gpu_health_requested
  end

  test "GPU encode falls through immediately when the pool is not ready", %{
    output_path: output_path
  } do
    configure_gpu_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/health"
      assert get_req_header(conn, "authorization") == ["Bearer gpu-secret"]
      send_resp(conn, 503, ~s({"status":"starting"}))
    end)

    assert {:error, {:encoding_booster_not_ready, 503}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               booster: :gpu
             )

    refute File.exists?(output_path)
  end

  test "GPU encode starts only after a successful readiness check", %{
    output_path: output_path
  } do
    configure_gpu_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 2, fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer gpu-secret"]

      case {conn.method, conn.request_path} do
        {"GET", "/health"} -> send_resp(conn, 200, ~s({"status":"ok"}))
        {"POST", "/encode"} -> send_resp(conn, 200, "gpu-encoded")
      end
    end)

    assert {:ok, %{size_bytes: 21}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path,
               booster: :gpu
             )

    assert File.read!(output_path) == "faststart:gpu-encoded"
  end

  test "remuxes a streamed response with codec copy and faststart", %{
    output_path: output_path
  } do
    File.write!(output_path, "fragmented-mp4")
    owner = self()

    runner = fn executable, args ->
      send(owner, {:remux_command, executable, args})
      input_path = Enum.at(args, Enum.find_index(args, &(&1 == "-i")) + 1)
      remuxed_path = List.last(args)
      File.write!(remuxed_path, "faststart:" <> File.read!(input_path))
      {"", 0}
    end

    assert {:ok, %{size_bytes: 24}} =
             Faststart.remux(output_path, ffmpeg_bin: "/test/ffmpeg", runner: runner)

    assert File.read!(output_path) == "faststart:fragmented-mp4"

    assert_received {:remux_command, "/test/ffmpeg", args}
    assert Enum.chunk_every(args, 2, 1) |> Enum.any?(&(&1 == ["-c", "copy"]))
    assert Enum.chunk_every(args, 2, 1) |> Enum.any?(&(&1 == ["-movflags", "+faststart"]))
    assert List.last(args) != output_path
    assert Path.dirname(List.last(args)) == Path.dirname(output_path)
  end

  test "losslessly joins bounded MP4 chunks into one playable rendition" do
    ffmpeg_bin = System.find_executable("ffmpeg")
    ffprobe_bin = System.find_executable("ffprobe")

    if is_nil(ffmpeg_bin) or is_nil(ffprobe_bin) do
      assert true
    else
      tmp_dir =
        Path.join(
          Path.join(System.tmp_dir!(), "mave-flow"),
          "encoding_booster_concat_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      chunk_paths =
        for {color, index} <- [{"red", 0}, {"blue", 1}] do
          chunk_path = Path.join(tmp_dir, "chunk_#{index}.mp4")

          {_output, 0} =
            System.cmd(
              ffmpeg_bin,
              [
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=#{color}:s=640x360:r=24:d=1",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=#{440 + index * 110}:duration=1",
                "-shortest",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-movflags",
                "+faststart",
                chunk_path
              ],
              stderr_to_stdout: true
            )

          chunk_path
        end

      output_path = Path.join(tmp_dir, "joined.mp4")
      assert {:ok, %{size_bytes: size_bytes}} = Concat.join(chunk_paths, output_path)
      assert size_bytes > 0

      {duration, 0} =
        System.cmd(
          ffprobe_bin,
          [
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            output_path
          ],
          stderr_to_stdout: true
        )

      {duration, _rest} = duration |> String.trim() |> Float.parse()
      assert duration >= 1.9
    end
  end

  test "preserves the streamed response when remuxing fails", %{output_path: output_path} do
    File.write!(output_path, "fragmented-mp4")

    runner = fn _executable, args ->
      File.write!(List.last(args), "partial-remux")
      {"remux failed", 1}
    end

    assert {:error, {:encoding_booster_remux_failed, 1}} =
             Faststart.remux(output_path, ffmpeg_bin: "/test/ffmpeg", runner: runner)

    assert File.read!(output_path) == "fragmented-mp4"
    assert Path.wildcard(output_path <> ".faststart-*.mp4") == []
  end

  test "removes the streamed response when final remuxing fails", %{output_path: output_path} do
    configure_booster()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(
      :mave_core,
      :encoding_booster_faststart_adapter,
      FailingFaststartAdapterStub
    )

    Req.Test.expect(__MODULE__, fn conn ->
      send_resp(conn, 200, "fragmented-mp4")
    end)

    assert {:error, {:encoding_booster_remux_failed, 1}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  test "removes a partial response when the booster is busy", %{output_path: output_path} do
    configure_booster(retry_backoff_ms: [])
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      send_resp(conn, 429, "busy")
    end)

    assert {:error, :encoding_booster_busy} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  test "retries transient capacity responses before succeeding", %{output_path: output_path} do
    configure_booster(retry_backoff_ms: [0, 0, 0], retry_jitter_ms: 0)
    Req.default_options(plug: {Req.Test, __MODULE__})
    counter = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 4, fn conn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> send_resp(conn, 500, "starting")
        2 -> send_resp(conn, 429, "busy")
        3 -> send_resp(conn, 503, "scaling")
        4 -> send_resp(conn, 200, "encoded-after-scale-out")
      end
    end)

    assert {:ok, %{size_bytes: 33}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    assert File.read!(output_path) == "faststart:encoded-after-scale-out"
  end

  test "does not retry a booster response caused by an invalid source", %{
    output_path: output_path
  } do
    configure_booster(retry_backoff_ms: [0, 0, 0], retry_jitter_ms: 0)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 1, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        502,
        Jason.encode!(%{"error" => "source returned HTTP 403"})
      )
    end)

    assert {:error, {:encoding_booster_http_status, 502, "source returned HTTP 403"}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  test "uses a longer independent retry budget while serverless capacity scales", %{
    output_path: output_path
  } do
    configure_booster(
      retry_backoff_ms: [],
      busy_retry_backoff_ms: [0, 0, 0, 0],
      retry_jitter_ms: 0
    )

    Req.default_options(plug: {Req.Test, __MODULE__})
    counter = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 5, fn conn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) < 5,
        do: send_resp(conn, 429, "busy"),
        else: send_resp(conn, 200, "encoded-after-capacity")
    end)

    assert {:ok, %{size_bytes: 32}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    assert File.read!(output_path) == "faststart:encoded-after-capacity"
  end

  test "retries a transient transport failure", %{output_path: output_path} do
    configure_booster(retry_backoff_ms: [0], retry_jitter_ms: 0)
    Req.default_options(plug: {Req.Test, __MODULE__})
    counter = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 2, fn conn ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> Req.Test.transport_error(conn, :timeout)
        2 -> send_resp(conn, 200, "encoded-after-timeout")
      end
    end)

    assert {:ok, %{size_bytes: 31}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    assert File.read!(output_path) == "faststart:encoded-after-timeout"
  end

  test "requires HTTPS for both the endpoint and source", %{output_path: output_path} do
    Application.put_env(:mave_core, :encoding_booster,
      enabled: true,
      endpoint: "http://booster.example",
      iam_secret_key: "secret-key"
    )

    assert {:error, :encoding_booster_endpoint_must_be_https} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    configure_booster()

    assert {:error, :encoding_booster_input_must_be_https} =
             EncodingBooster.encode_to_file("http://source.example/video.mp4", output_path)

    assert {:error, :encoding_booster_input_basic_auth_invalid} =
             EncodingBooster.encode_to_file(
               "https://video:%0Apassword@source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  test "rejects a private booster address without creating an output file", %{
    output_path: output_path
  } do
    configure_booster()

    Application.put_env(:mave_core, :public_http_url_resolver, fn
      "source.example" -> {:ok, [{93, 184, 216, 34}]}
      "booster.example" -> {:ok, [{10, 0, 0, 12}]}
    end)

    assert {:error, {:blocked_address, {10, 0, 0, 12}}} =
             EncodingBooster.encode_to_file(
               "https://source.example/video.mp4",
               output_path
             )

    refute File.exists?(output_path)
  end

  defp configure_booster(overrides \\ []) do
    config =
      [
        enabled: true,
        endpoint: "https://booster.example",
        iam_secret_key: "secret-key",
        fallback_enabled: true,
        connect_timeout_ms: 1_000,
        receive_timeout_ms: 5_000,
        retry_backoff_ms: [],
        retry_jitter_ms: 0
      ]
      |> Keyword.merge(overrides)

    Application.put_env(:mave_core, :encoding_booster, config)
  end

  defp configure_gpu_booster(overrides \\ []) do
    config =
      [
        enabled: true,
        endpoint: "http://10.0.0.20:8080",
        bearer_token: "gpu-secret",
        fallback_enabled: true,
        readiness_check_enabled: true,
        readiness_timeout_ms: 1_000,
        connect_timeout_ms: 1_000,
        receive_timeout_ms: 5_000,
        retry_backoff_ms: [],
        retry_jitter_ms: 0
      ]
      |> Keyword.merge(overrides)

    Application.put_env(:mave_core, :gpu_encoding_booster, config)
  end

  defp encoding_bundle do
    {:ok, {_name, bundle}} =
      :zip.create(
        ~c"encoding-bundle.zip",
        [
          {~c"encoded.mp4", "encoded-mp4"},
          {~c"hls/init.mp4", "init"},
          {~c"hls/playlist.m3u8", "#EXTM3U\n"},
          {~c"hls/segment_000.m4s", "segment"}
        ],
        [:memory, {:compress, []}]
      )

    bundle
  end

  defp hls_bundle do
    {:ok, {_name, bundle}} =
      :zip.create(
        ~c"hls-bundle.zip",
        [
          {~c"hls/init.mp4", "init"},
          {~c"hls/playlist.m3u8", "#EXTM3U\n"},
          {~c"hls/segment_000.m4s", "segment"}
        ],
        [:memory, {:compress, []}]
      )

    bundle
  end

  # Generated by Go archive/zip using zip.Store on a non-seekable writer. It
  # includes the data descriptors used by the live encoding booster response.
  defp go_streaming_encoding_bundle do
    Base.decode64!(
      "UEsDBBQACAAAAAAAAAAAAAAAAAAAAAAAAAALAAAAZW5jb2RlZC5tcDRlbmNvZGVkLW1wNFBLBwhiNaG+CwAAAAsAAABQSwMEFAAIAAAAAAAAAAAAAAAAAAAAAAAAAAwAAABobHMvaW5pdC5tcDRpbml0UEsHCHTkdMYEAAAABAAAAFBLAwQUAAgAAAAAAAAAAAAAAAAAAAAAAAAAEQAAAGhscy9wbGF5bGlzdC5tM3U4I0VYVE0zVQpQSwcItZjsQQgAAAAIAAAAUEsDBBQACAAAAAAAAAAAAAAAAAAAAAAAAAATAAAAaGxzL3NlZ21lbnRfMDAwLm00c3NlZ21lbnRQSwcIZfWBGAcAAAAHAAAAUEsBAhQDFAAIAAAAAAAAAGI1ob4LAAAACwAAAAsAAAAAAAAAAAAAAICBAAAAAGVuY29kZWQubXA0UEsBAhQDFAAIAAAAAAAAAHTkdMYEAAAABAAAAAwAAAAAAAAAAAAAAICBRAAAAGhscy9pbml0Lm1wNFBLAQIUAxQACAAAAAAAAAC1mOxBCAAAAAgAAAARAAAAAAAAAAAAAACAgYIAAABobHMvcGxheWxpc3QubTN1OFBLAQIUAxQACAAAAAAAAABl9YEYBwAAAAcAAAATAAAAAAAAAAAAAACAgckAAABobHMvc2VnbWVudF8wMDAubTRzUEsFBgAAAAAEAAQA8wAAABEBAAAAAA=="
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
