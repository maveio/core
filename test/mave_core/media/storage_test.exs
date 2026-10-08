defmodule MaveCore.Media.StorageTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias MaveCore.Embeds.SettingsSerializer
  alias MaveCore.Media.Storage
  alias MaveCore.Spaces.{Domain, Space}

  setup {Req.Test, :verify_on_exit!}

  test "bucket overrides sign requests and presigned URLs for the correct account" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    profile = [
      endpoint: "https://storage.example.test",
      region: "fr-par",
      access_key_id: "primary-key",
      secret_access_key: "secret",
      bucket_overrides: %{"overflow" => [access_key_id: "overflow-key"]}
    ]

    Req.Test.expect(__MODULE__, 3, fn conn ->
      assert hd(get_req_header(conn, "authorization")) =~ "Credential=overflow-key/"
      send_resp(conn, 200, "")
    end)

    assert {:ok, ""} = Storage.get("overflow", "object", profile)
    assert :ok = Storage.ensure_bucket("overflow", profile)
    assert :ok = Storage.put_bucket_cors("overflow", ["example.test"], profile)

    for {bucket, key} <- [{"overflow", "overflow-key"}, {"primary", "primary-key"}] do
      assert {:ok, url} = Storage.presigned_get_url(bucket, "object", profile)

      credential =
        url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("X-Amz-Credential")

      assert String.starts_with?(credential, key <> "/")
    end
  end

  for operation <- [:copy_public, :copy_public_between_profiles] do
    test "#{operation} copies between bucket accounts within one profile" do
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)
      Req.default_options(plug: {Req.Test, __MODULE__})

      profile = [
        endpoint: "https://storage.example.test",
        region: "fr-par",
        access_key_id: "primary-key",
        secret_access_key: "secret",
        bucket_overrides: %{"overflow" => [access_key_id: "overflow-key"]}
      ]

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "HEAD"
        assert hd(get_req_header(conn, "authorization")) =~ "Credential=primary-key/"
        conn |> put_resp_header("content-length", "4") |> send_resp(200, "")
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert hd(get_req_header(conn, "authorization")) =~ "Credential=primary-key/"
        send_resp(conn, 200, "test")
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/overflow/object"
        assert get_req_header(conn, "x-amz-copy-source") == []
        assert hd(get_req_header(conn, "authorization")) =~ "Credential=overflow-key/"
        assert Req.Test.raw_body(conn) == "test"
        send_resp(conn, 200, "")
      end)

      result =
        case unquote(operation) do
          :copy_public ->
            Storage.copy_public("overflow", "object", "primary", "object", profile)

          :copy_public_between_profiles ->
            Storage.copy_public_between_profiles(
              "overflow",
              "object",
              profile,
              "primary",
              "object",
              profile
            )
        end

      assert :ok = result
    end
  end

  for operation <- [:get, :ensure_bucket] do
    @tag operation: operation, signing_retry: true
    test "#{operation} signs retries without including the previous signature headers", %{
      operation: operation
    } do
      Req.default_options(plug: {Req.Test, __MODULE__}, retry_delay: fn _ -> 0 end)

      profile = [
        access_key_id: "test-access-key",
        secret_access_key: "test-secret-key",
        endpoint: "http://storage.example.test",
        region: "fr-par"
      ]

      Req.Test.expect(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      Req.Test.expect(__MODULE__, fn conn ->
        headers =
          Enum.reject(conn.req_headers, fn {key, _} ->
            key in [
              "authorization",
              "x-amz-date",
              "x-amz-content-sha256",
              "accept-encoding",
              "user-agent"
            ]
          end)

        [date] = get_req_header(conn, "x-amz-date")
        {:ok, datetime, _} = DateTime.from_iso8601(date, :basic)

        expected =
          Req.Utils.aws_sigv4_headers(
            access_key_id: profile[:access_key_id],
            secret_access_key: profile[:secret_access_key],
            region: profile[:region],
            service: "s3",
            datetime: datetime,
            method: if(operation == :get, do: :get, else: :head),
            url: "#{profile[:endpoint]}#{conn.request_path}",
            headers: headers,
            body: ""
          )

        {"authorization", authorization} = List.keyfind(expected, "authorization", 0)
        assert get_req_header(conn, "authorization") == [authorization]
        send_resp(conn, 200, "")
      end)

      case operation do
        :get -> assert {:ok, ""} = Storage.get("bucket", "manifest.json", profile)
        :ensure_bucket -> assert :ok = Storage.ensure_bucket("bucket", profile)
      end
    end
  end

  setup do
    previous_req_options = Req.default_options()
    original_domain = Application.get_env(:mave_core, :domain)
    original_public_cdn_scheme = Application.get_env(:mave_core, :public_cdn_scheme)
    original_public_cdn_host = Application.get_env(:mave_core, :public_cdn_host)
    original_public_cdn_mode = Application.get_env(:mave_core, :public_cdn_mode)
    original_s3 = Application.get_env(:mave_core, :s3)
    original_upload = Application.get_env(:mave_core, :upload)
    original_storage_providers = Application.get_env(:mave_core, :storage_providers)

    original_object_acl_storage_profiles =
      Application.get_env(:mave_core, :object_acl_storage_profiles)

    Application.put_env(:mave_core, :domain, "https://app.example.test")
    Application.put_env(:mave_core, :public_cdn_scheme, "https")
    Application.put_env(:mave_core, :public_cdn_host, "video-dns.com")

    on_exit(fn ->
      Req.default_options(previous_req_options)

      if is_nil(original_domain) do
        Application.delete_env(:mave_core, :domain)
      else
        Application.put_env(:mave_core, :domain, original_domain)
      end

      if is_nil(original_public_cdn_host) do
        Application.delete_env(:mave_core, :public_cdn_host)
      else
        Application.put_env(:mave_core, :public_cdn_host, original_public_cdn_host)
      end

      if is_nil(original_public_cdn_scheme) do
        Application.delete_env(:mave_core, :public_cdn_scheme)
      else
        Application.put_env(:mave_core, :public_cdn_scheme, original_public_cdn_scheme)
      end

      if is_nil(original_public_cdn_mode) do
        Application.delete_env(:mave_core, :public_cdn_mode)
      else
        Application.put_env(:mave_core, :public_cdn_mode, original_public_cdn_mode)
      end

      if is_nil(original_s3) do
        Application.delete_env(:mave_core, :s3)
      else
        Application.put_env(:mave_core, :s3, original_s3)
      end

      if is_nil(original_upload) do
        Application.delete_env(:mave_core, :upload)
      else
        Application.put_env(:mave_core, :upload, original_upload)
      end

      if is_nil(original_storage_providers) do
        Application.delete_env(:mave_core, :storage_providers)
      else
        Application.put_env(:mave_core, :storage_providers, original_storage_providers)
      end

      if is_nil(original_object_acl_storage_profiles) do
        Application.delete_env(:mave_core, :object_acl_storage_profiles)
      else
        Application.put_env(
          :mave_core,
          :object_acl_storage_profiles,
          original_object_acl_storage_profiles
        )
      end
    end)

    :ok
  end

  test "storage profiles can separate physical bucket names from public CDN aliases" do
    Application.put_env(:mave_core, :storage_providers, %{
      "eu_4" => [
        bucket_prefix: "mave-",
        public_bucket_prefix: "space-"
      ]
    })

    assert Storage.bucket_for_space("3jqm2", "eu_4") == "mave-3jqm2"
    assert Storage.public_bucket_for_space("3jqm2", "eu_4") == "space-3jqm2"
    assert Storage.public_bucket_name("mave-3jqm2") == "space-3jqm2"
    assert Storage.public_bucket_name("mave-upload") == "mave-upload"

    assert SettingsSerializer.storage_object_url("mave-3jqm2", "embed/manifest.json") ==
             "https://space-3jqm2.video-dns.com/embed/manifest.json"

    Application.put_env(:mave_core, :public_cdn_mode, :direct_s3)
    Application.put_env(:mave_core, :upload, source_base_url: "http://localhost:9000")

    assert SettingsSerializer.storage_object_url("mave-3jqm2", "embed/manifest.json") ==
             "http://mave-3jqm2.localhost/embed/manifest.json"
  end

  test "upload public URLs use the configured browser origin without the physical bucket" do
    Application.put_env(:mave_core, :upload,
      bucket: "mave-upload",
      source_base_url: "https://s3.fr-par.scw.cloud",
      public_base_url: "https://storage.video-dns.com/"
    )

    assert Storage.upload_public_object_url("ubg50/video.mp4") ==
             "https://storage.video-dns.com/ubg50/video.mp4"

    assert Storage.upload_public_url?("https://storage.video-dns.com/ubg50/video.mp4")
    refute Storage.upload_public_url?("https://storage.video-dns.com.evil.test/ubg50/video.mp4")
  end

  test "upload public URLs fall back to the direct upload bucket origin" do
    Application.put_env(:mave_core, :upload,
      bucket: "example-uploads",
      source_base_url: "https://s3.fr-par.scw.cloud",
      public_base_url: nil
    )

    assert Storage.upload_public_object_url("rbp63/video.mp4") ==
             "https://s3.fr-par.scw.cloud/example-uploads/rbp63/video.mp4"

    assert Storage.upload_public_url?(
             "https://s3.fr-par.scw.cloud/example-uploads/rbp63/video.mp4"
           )
  end

  test "ffmpeg_input_url routes upload objects through the direct storage origin" do
    Application.put_env(:mave_core, :upload,
      bucket: "mave-upload",
      source_base_url: "https://s3.fr-par.scw.cloud",
      public_base_url: "https://storage.video-dns.com/"
    )

    assert Storage.ffmpeg_input_url(
             "mave-upload",
             "/ubg50/my original.mp4",
             "fr-par"
           ) ==
             {:ok, "https://s3.fr-par.scw.cloud/mave-upload/ubg50/my%20original.mp4"}

    assert Storage.upload_public_object_url("ubg50/my original.mp4") ==
             "https://storage.video-dns.com/ubg50/my original.mp4"
  end

  test "put_public uses profile-level object ACL opt-in" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "mett" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-",
        object_acl: true
      ]
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-mett/manifest.json"
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]

      send_resp(conn, 200, "")
    end)

    assert {:ok, ""} =
             Storage.put_public(
               "space-mett",
               "manifest.json",
               "{}",
               "application/json",
               "mett"
             )
  end

  test "put_public retries transient transport failures" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    attempts = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 3, fn conn ->
      :counters.add(attempts, 1, 1)
      assert conn.method == "PUT"
      assert conn.request_path == "/space-retry/segment_002.webp"
      assert Req.Test.raw_body(conn) == "segment-body"

      case :counters.get(attempts, 1) do
        1 -> Req.Test.transport_error(conn, :closed)
        2 -> Req.Test.transport_error(conn, :timeout)
        3 -> send_resp(conn, 200, "")
      end
    end)

    assert {:ok, ""} =
             Storage.put_public(
               "space-retry",
               "segment_002.webp",
               "segment-body",
               "image/webp",
               "retry"
             )
  end

  test "put_public retries object-store write conflicts" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    attempts = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 2, fn conn ->
      :counters.add(attempts, 1, 1)
      assert conn.method == "PUT"
      assert conn.request_path == "/space-retry/embed/manifest.json"
      assert Req.Test.raw_body(conn) == ~s({"status":"playable"})

      case :counters.get(attempts, 1) do
        1 -> send_resp(conn, 409, "")
        2 -> send_resp(conn, 200, "")
      end
    end)

    assert {:ok, ""} =
             Storage.put_public(
               "space-retry",
               "embed/manifest.json",
               ~s({"status":"playable"}),
               "application/json",
               "retry"
             )
  end

  test "put_file_public retries and replays a streamed file body" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    source_path =
      Path.join(
        System.tmp_dir!(),
        "storage_put_retry_#{System.unique_integer([:positive])}.m4s"
      )

    File.write!(source_path, "hls-segment-body")

    on_exit(fn -> File.rm(source_path) end)

    attempts = :counters.new(1, [])

    Req.Test.expect(__MODULE__, 2, fn conn ->
      :counters.add(attempts, 1, 1)
      assert conn.method == "PUT"
      assert conn.request_path == "/space-retry/hls_h264_hd/segment_003.m4s"
      assert Req.Test.raw_body(conn) == "hls-segment-body"

      case :counters.get(attempts, 1) do
        1 -> Req.Test.transport_error(conn, :timeout)
        2 -> send_resp(conn, 200, "")
      end
    end)

    assert {:ok, ""} =
             Storage.put_file_public(
               "space-retry",
               "hls_h264_hd/segment_003.m4s",
               source_path,
               "video/mp4",
               "retry"
             )
  end

  test "put retries transient failures with a fresh signed request" do
    attempts = :counters.new(1, [])

    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 2, fn conn ->
      :counters.add(attempts, 1, 1)
      attempt = :counters.get(attempts, 1)

      assert conn.method == "PUT"
      assert conn.request_path == "/space-retry/manifest.json"
      assert length(get_req_header(conn, "authorization")) == 1

      case attempt do
        1 -> Req.Test.transport_error(conn, :timeout)
        2 -> send_resp(conn, 200, "")
      end
    end)

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    assert {:ok, ""} =
             Storage.put_public(
               "space-retry",
               "manifest.json",
               "{}",
               "application/json",
               "retry"
             )

    assert :counters.get(attempts, 1) == 2
  end

  test "object_info retries transient HEAD failures with fresh signed requests" do
    attempts = :counters.new(1, [])

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    Req.Test.expect(__MODULE__, 3, fn conn ->
      :counters.add(attempts, 1, 1)
      attempt = :counters.get(attempts, 1)

      assert conn.method == "HEAD"
      assert conn.request_path == "/space-retry/video_h264_fhd.mp4"
      assert length(get_req_header(conn, "authorization")) == 1

      case attempt do
        1 ->
          send_resp(conn, 403, "")

        2 ->
          Req.Test.transport_error(conn, :closed)

        3 ->
          conn
          |> put_resp_header("content-length", "726484352")
          |> put_resp_header("content-type", "video/mp4")
          |> put_resp_header("x-amz-meta-mave-sha256", "test-digest")
          |> send_resp(200, "")
      end
    end)

    assert {:ok,
            %{
              size_bytes: 726_484_352,
              content_type: "video/mp4",
              sha256: "test-digest"
            }} =
             Storage.object_info(
               "space-retry",
               "video_h264_fhd.mp4",
               "retry"
             )

    assert :counters.get(attempts, 1) == 3
  end

  test "object_info bounds persistent transient HEAD retries" do
    attempts = :counters.new(1, [])

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    Req.Test.expect(__MODULE__, 4, fn conn ->
      :counters.add(attempts, 1, 1)
      assert conn.method == "HEAD"
      send_resp(conn, 403, "")
    end)

    assert {:error, {:object_info_failed, 403}} =
             Storage.object_info("space-retry", "video_h264_fhd.mp4", "retry")

    assert :counters.get(attempts, 1) == 4
  end

  test "object_info does not retry missing objects" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "retry" => [
        access_key_id: "minioadmin",
        secret_access_key: "minioadmin",
        endpoint: "http://localhost:9010",
        region: "fr-par",
        bucket_prefix: "space-"
      ]
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      send_resp(conn, 404, "")
    end)

    assert {:error, :not_found} =
             Storage.object_info("space-retry", "missing.mp4", "retry")
  end

  @tag :integration
  test "put/3 and get/2 lifecycle" do
    # Use the bucket from seeds: "space-ubg50"
    bucket = "space-ubg50"
    path = "integration_test_#{System.unique_integer()}.txt"
    content = "Hello Integration"

    # 1. Put
    assert {:ok, _} = Storage.put(bucket, path, content)

    # 2. Exists
    assert Storage.exists?(bucket, path)

    # 3. Get
    assert {:ok, fetched} = Storage.get(bucket, path)
    assert fetched == content

    # 4. Not Found
    assert {:error, :not_found} = Storage.get(bucket, "non_existent.txt")
  end

  test "build_allowed_origins expands defaults and custom domains" do
    origins = Storage.build_allowed_origins(["example.com", "https://custom.example.org"])

    assert "https://app.example.test" in origins
    assert "http://app.example.test" in origins
    assert "https://dash.example.test" in origins
    assert "http://dash.example.test" in origins
    assert "http://localhost:*" in origins
    assert "http://127.0.0.1:*" in origins
    assert "https://video-dns.com" in origins
    assert "https://*.video-dns.com" in origins
    assert "https://example.com" in origins
    assert "http://example.com" in origins
    assert "https://custom.example.org" in origins
  end

  test "ffmpeg_input_url returns an unsigned encoded S3 object URL" do
    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.example.test",
      region: "fr-par"
    )

    assert {:ok, url} = Storage.ffmpeg_input_url("space-demo", "/video/my original.mp4")
    assert url == "https://s3.example.test/space-demo/video/my%20original.mp4"
    refute url =~ "?"
  end

  test "ffmpeg_input_referer is derived without exposing the internal secret" do
    referer = Storage.ffmpeg_input_referer()

    assert String.starts_with?(referer, "https://ffmpeg.storage.mave.invalid/")
    refute referer =~ Application.fetch_env!(:mave_core, :internal_secret)
    assert referer == Storage.ffmpeg_input_referer()
  end

  test "ffmpeg_storage_url? only accepts configured storage origins and paths" do
    Application.put_env(:mave_core, :upload,
      bucket: "mave-upload",
      source_base_url: "https://uploads.example.test/private"
    )

    assert Storage.upload_storage_url?(
             "https://uploads.example.test/private/mave-upload/rbp63/video.mp4"
           )

    refute Storage.ffmpeg_storage_url?(
             "https://uploads.example.test/private/mave-upload/rbp63/video.mp4"
           )

    assert Storage.ffmpeg_storage_url?(
             "https://uploads.example.test/private/space-demo/video.mp4"
           )

    refute Storage.upload_storage_url?("https://uploads.example.test/private/mave-upload-copy/x")

    refute Storage.ffmpeg_storage_url?("https://uploads.example.test/public/video.mp4")
    refute Storage.ffmpeg_storage_url?("https://uploads.example.test.evil/video.mp4")
    refute Storage.ffmpeg_storage_url?("https://example.com/video.mp4")
  end

  test "presigned storage URLs do not require the private FFmpeg Referer" do
    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.example.test",
      region: "fr-par"
    )

    signed_url =
      "https://s3.example.test/space-demo/video.mp4?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=abc123"

    assert Storage.presigned_storage_url?(signed_url)
    refute Storage.ffmpeg_referer_required?(signed_url)

    unsigned_url = "https://s3.example.test/space-demo/video.mp4"
    refute Storage.presigned_storage_url?(unsigned_url)
    assert Storage.ffmpeg_referer_required?(unsigned_url)
  end

  test "get_prefix reads only the bounded beginning of a storage object" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.example.test",
      region: "fr-par"
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/space-demo/video.mp4"

      conn
      |> put_resp_header("content-length", "2048")
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    prefix = :binary.copy(<<1>>, 1_024)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/space-demo/video.mp4"
      assert get_req_header(conn, "range") == ["bytes=0-1023"]
      send_resp(conn, 206, prefix)
    end)

    assert {:ok, ^prefix} = Storage.get_prefix("space-demo", "video.mp4", nil, 1_024)
  end

  test "get decodes JSON object responses for compatibility" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    body = ~s({"id":"trial"})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/space-trial/embed/manifest.json"

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, body)
    end)

    assert {:ok, %{"id" => "trial"}} = Storage.get("space-trial", "embed/manifest.json")
  end

  test "prefix_empty? distinguishes empty and populated prefixes" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/space-recyclable/"
      assert conn.query_params["list-type"] == "2"
      assert conn.query_params["prefix"] == ""

      send_resp(conn, 200, "<ListBucketResult></ListBucketResult>")
    end)

    assert {:ok, true} = Storage.prefix_empty?("space-recyclable", "")

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/space-recyclable/"
      assert conn.query_params["prefix"] == ""

      send_resp(
        conn,
        200,
        "<ListBucketResult><Contents><Key>embed/original</Key></Contents></ListBucketResult>"
      )
    end)

    assert {:ok, false} = Storage.prefix_empty?("space-recyclable", "")
  end

  test "download_to_file writes raw JSON object bytes" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    body = ~s({"id":"trial"})
    tmp_path = Path.join(System.tmp_dir!(), "mave-storage-test-#{System.unique_integer()}.json")

    on_exit(fn -> File.rm(tmp_path) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/space-trial/embed/manifest.json"

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, body)
    end)

    assert :ok = Storage.download_to_file("space-trial", "embed/manifest.json", tmp_path)
    assert File.read!(tmp_path) == body
  end

  test "download_to_file times out stalled downloads and removes the destination file" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    tmp_path =
      Path.join(System.tmp_dir!(), "mave-storage-timeout-test-#{System.unique_integer()}")

    on_exit(fn -> File.rm(tmp_path) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/space-trial/embed/original"

      receive do
        :continue -> send_resp(conn, 200, "late")
      end
    end)

    assert {:error, {:storage_request_timeout, 100}} =
             Storage.download_to_file("space-trial", "embed/original", tmp_path, nil,
               timeout: 100
             )

    refute File.exists?(tmp_path)
  end

  test "copy_public_between_profiles streams small JSON objects as raw bytes" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "eu" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    source_body = ~s({"outputs":["manifest"]})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/embed/manifest.json"

      conn
      |> put_resp_header("content-length", Integer.to_string(byte_size(source_body) + 5))
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/mave-upload/uploads/embed/manifest.json"

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, source_body)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/manifest.json"
      assert get_req_header(conn, "content-type") == ["application/json"]
      assert get_req_header(conn, "content-length") == [Integer.to_string(byte_size(source_body))]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      assert Req.Test.raw_body(conn) == source_body

      send_resp(conn, 200, "")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-ccmhz",
               "NRH03s0Zi0/manifest.json",
               "eu",
               "mave-upload",
               "uploads/embed/manifest.json",
               "fr-par",
               server_side_copy?: false,
               single_put_max_bytes: 1024
             )
  end

  test "copy_public_between_profiles treats identical storage configs as one backend" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    local_provider = [
      access_key_id: "minioadmin",
      secret_access_key: "minioadmin",
      endpoint: "http://localhost:9010",
      region: "us-east-1",
      bucket_prefix: "space-"
    ]

    Application.put_env(:mave_core, :storage_providers, %{
      "eu" => local_provider,
      "eu_3" => Keyword.put(local_provider, :endpoint, "http://localhost:9010/")
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-next/NRH03s0Zi0/original"
      assert get_req_header(conn, "x-amz-copy-source") == ["/space-trial/NRH03s0Zi0/original"]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      assert Req.Test.raw_body(conn) == ""

      send_resp(conn, 200, "")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-next",
               "NRH03s0Zi0/original",
               "eu",
               "space-trial",
               "NRH03s0Zi0/original",
               "eu_3"
             )
  end

  test "copy_public_between_profiles uses S3 server-side copy across profiles" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    destination_config = [
      access_key_id: "dest-key",
      secret_access_key: "dest-secret",
      endpoint: "https://storage.example.test",
      region: "fr-par",
      object_acl: true
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/embed/original.mp4"

      conn
      |> put_resp_header("content-length", "1024")
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/original.mp4"

      assert get_req_header(conn, "x-amz-copy-source") == [
               "/mave-upload/uploads/embed/original.mp4"
             ]

      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      assert Req.Test.raw_body(conn) == ""

      send_resp(conn, 200, "<CopyObjectResult />")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-mett",
               "NRH03s0Zi0/original.mp4",
               destination_config,
               "mave-upload",
               "uploads/embed/original.mp4",
               "fr-par",
               server_side_copy?: true
             )
  end

  test "sanitize_public_object_metadata replaces user metadata with a server-side copy" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    storage_config = [
      access_key_id: "upload-key",
      secret_access_key: "upload-secret",
      endpoint: "https://storage.example.test",
      region: "fr-par",
      object_acl: true
    ]

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/corre/original.mov"

      conn
      |> put_resp_header("content-length", "1024")
      |> put_resp_header("content-type", "video/quicktime")
      |> put_resp_header("x-amz-meta-token", "must-not-survive")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/mave-upload/corre/original.mov"
      assert get_req_header(conn, "x-amz-copy-source") == ["/mave-upload/corre/original.mov"]
      assert get_req_header(conn, "x-amz-metadata-directive") == ["REPLACE"]
      assert get_req_header(conn, "content-type") == ["video/quicktime"]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      assert get_req_header(conn, "x-amz-meta-token") == []
      assert Req.Test.raw_body(conn) == ""

      send_resp(conn, 200, "<CopyObjectResult />")
    end)

    assert :ok =
             Storage.sanitize_public_object_metadata(
               "mave-upload",
               "corre/original.mov",
               storage_config
             )
  end

  test "copy_public_between_profiles falls back to proxy copy when server-side copy is unavailable" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "mett" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par",
        object_acl: true
      ]
    })

    source_body = ~s({"outputs":["manifest"]})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/embed/manifest.json"

      conn
      |> put_resp_header("content-length", Integer.to_string(byte_size(source_body)))
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/manifest.json"

      assert get_req_header(conn, "x-amz-copy-source") == [
               "/mave-upload/uploads/embed/manifest.json"
             ]

      send_resp(conn, 403, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/mave-upload/uploads/embed/manifest.json"

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, source_body)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/manifest.json"
      assert get_req_header(conn, "content-type") == ["application/json"]
      assert get_req_header(conn, "content-length") == [Integer.to_string(byte_size(source_body))]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      assert Req.Test.raw_body(conn) == source_body

      send_resp(conn, 200, "")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-mett",
               "NRH03s0Zi0/manifest.json",
               "mett",
               "mave-upload",
               "uploads/embed/manifest.json",
               "fr-par",
               server_side_copy?: true
             )
  end

  test "copy_public_between_profiles uses S3 multipart server-side copy across profiles" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "mett" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par",
        object_acl: true
      ]
    })

    part_size = 5 * 1024 * 1024
    source_size = part_size + 4

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"

      conn
      |> put_resp_header("content-length", Integer.to_string(source_size))
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/original"
      assert conn.query_string == "uploads"
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>upload-123</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    expect_part_copy("1", "bytes=0-5242879", ~s("etag-1"))
    expect_part_copy("2", "bytes=5242880-5242883", ~s("etag-2"))

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/original"
      assert conn.query_params["uploadId"] == "upload-123"

      body = Req.Test.raw_body(conn)
      assert body =~ "<PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag>"
      assert body =~ "<PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag>"

      send_resp(conn, 200, "<CompleteMultipartUploadResult />")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-mett",
               "NRH03s0Zi0/original",
               "mett",
               "mave-upload",
               "uploads/source.mp4",
               "fr-par",
               part_concurrency: 1,
               server_side_copy?: true,
               server_side_copy_max_bytes: part_size - 1,
               server_side_part_size: part_size
             )
  end

  test "creates scoped multipart URLs for a direct booster destination" do
    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "qingb" => [
        access_key_id: "destination-key",
        secret_access_key: "destination-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par",
        object_acl: true
      ]
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/space-qingb/embed/h264_hd.mp4"
      assert conn.query_string == "uploads"
      assert get_req_header(conn, "content-type") == ["video/mp4"]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>direct-upload-123</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    assert {:ok, session} =
             Storage.start_presigned_multipart_upload(
               "space-qingb",
               "embed/h264_hd.mp4",
               "qingb",
               "video/mp4",
               max_bytes: 200 * 1024 * 1024
             )

    assert session.upload_id == "direct-upload-123"
    assert session.payload["part_size_bytes"] == 16 * 1024 * 1024
    assert length(session.payload["part_urls"]) == 14

    assert Enum.with_index(session.payload["part_urls"], 1)
           |> Enum.all?(fn {url, part_number} ->
             uri = URI.parse(url)
             params = URI.decode_query(uri.query)

             uri.scheme == "https" and uri.host == "storage.example.test" and
               uri.path == "/space-qingb/embed/h264_hd.mp4" and
               params["partNumber"] == Integer.to_string(part_number) and
               params["uploadId"] == "direct-upload-123" and
               is_binary(params["X-Amz-Signature"])
           end)

    for key <- ["complete_url", "abort_url"] do
      params = session.payload[key] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["uploadId"] == "direct-upload-123"
      assert is_binary(params["X-Amz-Signature"])
    end
  end

  test "creates a private multipart destination when requested" do
    Req.Test.set_req_test_to_shared()
    Req.default_options(plug: {Req.Test, __MODULE__})

    storage_profile = %{
      access_key_id: "destination-key",
      secret_access_key: "destination-secret",
      endpoint: "https://storage.example.test",
      region: "fsn1",
      object_acl: true
    }

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert get_req_header(conn, "x-amz-acl") == []

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>private-upload</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    assert {:ok, %{upload_id: "private-upload"}} =
             Storage.start_presigned_multipart_upload(
               "mave-media-backup",
               "space/source.mp4",
               storage_profile,
               "video/mp4",
               max_bytes: 200 * 1024 * 1024,
               public: false
             )
  end

  test "creates a header-bound PUT URL for one booster-published HLS object" do
    Application.put_env(:mave_core, :storage_providers, %{
      "qingb" => [
        access_key_id: "destination-key",
        secret_access_key: "destination-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par",
        object_acl: true
      ]
    })

    assert {:ok, %{"url" => url, "headers" => headers}} =
             Storage.presigned_put_url(
               "space-qingb",
               "embed/h264_hd_hls/segment_000.m4s",
               "qingb",
               "video/mp4",
               12_345
             )

    uri = URI.parse(url)
    params = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "storage.example.test"
    assert uri.path == "/space-qingb/embed/h264_hd_hls/segment_000.m4s"
    assert is_binary(params["X-Amz-Signature"])
    assert params["X-Amz-SignedHeaders"] == "content-length;content-type;host;x-amz-acl"

    assert headers == %{
             "content-length" => "12345",
             "content-type" => "video/mp4",
             "x-amz-acl" => "public-read"
           }
  end

  test "copy_prefix_public skips destination objects with matching size" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    provider = [
      access_key_id: "key",
      secret_access_key: "secret",
      endpoint: "https://storage.example.test",
      region: "fr-par",
      object_acl: true
    ]

    Application.put_env(:mave_core, :storage_providers, %{
      "eu" => provider,
      "mett" => provider
    })

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/space-source/"
      assert conn.query_params["list-type"] == "2"
      assert conn.query_params["prefix"] == "embed/"

      send_resp(
        conn,
        200,
        """
        <ListBucketResult>
          <Contents><Key>embed/existing.json</Key></Contents>
          <Contents><Key>embed/missing.json</Key></Contents>
        </ListBucketResult>
        """
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/space-source/embed/existing.json"

      conn
      |> put_resp_header("content-length", "5")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/space-destination/embed/existing.json"

      conn
      |> put_resp_header("content-length", "5")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/space-source/embed/missing.json"

      conn
      |> put_resp_header("content-length", "7")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/space-destination/embed/missing.json"

      send_resp(conn, 404, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/space-destination/embed/missing.json"
      assert get_req_header(conn, "x-amz-copy-source") == ["/space-source/embed/missing.json"]
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]

      send_resp(conn, 200, "")
    end)

    assert :ok =
             Storage.copy_prefix_public(
               "space-destination",
               "embed/",
               "mett",
               "space-source",
               "embed/",
               "eu"
             )
  end

  test "update_embed_visibility skips object ACLs for profiles without ACL support" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "eu_2" => [
        access_key_id: "r2-key",
        secret_access_key: "r2-secret",
        endpoint: "https://r2.example.test",
        region: "auto"
      ]
    })

    space = %Space{id: "space-id", hash: "ubg50", region: "eu_2"}

    assert :ok = Storage.update_embed_visibility(space, "07j2bvselT", "private", "eu_2")
  end

  test "set_object_visibility publishes one completed upload with an object ACL" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "upload-key",
        secret_access_key: "upload-secret",
        endpoint: "https://s3.fr-par.scw.cloud",
        region: "fr-par"
      ]
    })

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/mave-upload/uploads/public/source.mp4"
      assert conn.query_string == "acl"
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]
      send_resp(conn, 200, "")
    end)

    assert :ok =
             Storage.set_object_visibility(
               "mave-upload",
               "uploads/public/source.mp4",
               "public",
               "fr-par"
             )
  end

  test "copy_public_between_profiles uploads large objects as bounded multipart ranges" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "eu" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    part_size = 5 * 1024 * 1024
    source_body = :binary.copy("a", part_size) <> :binary.copy("b", part_size) <> "tail"
    part_1 = binary_part(source_body, 0, part_size)
    part_2 = binary_part(source_body, part_size, part_size)
    part_3 = binary_part(source_body, part_size * 2, 4)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"

      conn
      |> put_resp_header("content-length", Integer.to_string(byte_size(source_body)))
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_string == "uploads"
      assert get_req_header(conn, "x-amz-acl") == ["public-read"]

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>upload-123</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    expect_range_get("bytes=0-5242879", part_1)
    expect_part_upload("1", part_1, ~s("etag-1"))
    expect_range_get("bytes=5242880-10485759", part_2)
    expect_part_upload("2", part_2, ~s("etag-2"))
    expect_range_get("bytes=10485760-10485763", part_3)
    expect_part_upload("3", part_3, ~s("etag-3"))

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_params["uploadId"] == "upload-123"

      body = Req.Test.raw_body(conn)
      assert body =~ "<PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag>"
      assert body =~ "<PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag>"
      assert body =~ "<PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag>"

      send_resp(conn, 200, "<CompleteMultipartUploadResult />")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-ccmhz",
               "NRH03s0Zi0/original",
               "eu",
               "mave-upload",
               "uploads/source.mp4",
               "fr-par",
               part_concurrency: 1,
               server_side_copy?: false,
               part_size: part_size,
               single_put_max_bytes: part_size - 1
             )
  end

  test "copy_public_between_profiles increases part size to stay within the part limit" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "eu" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    configured_part_size = 5 * 1024 * 1024

    source_body =
      :binary.copy("a", configured_part_size) <>
        :binary.copy("b", configured_part_size) <> "tail"

    effective_part_size = div(byte_size(source_body) + 1, 2)
    part_1 = binary_part(source_body, 0, effective_part_size)
    part_2 = binary_part(source_body, effective_part_size, effective_part_size)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"

      conn
      |> put_resp_header("content-length", Integer.to_string(byte_size(source_body)))
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_string == "uploads"

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>upload-123</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    expect_range_get("bytes=0-5242881", part_1)
    expect_part_upload("1", part_1, ~s("etag-1"))
    expect_range_get("bytes=5242882-10485763", part_2)
    expect_part_upload("2", part_2, ~s("etag-2"))

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_params["uploadId"] == "upload-123"

      body = Req.Test.raw_body(conn)
      assert body =~ "<PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag>"
      assert body =~ "<PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag>"
      refute body =~ "<PartNumber>3</PartNumber>"

      send_resp(conn, 200, "<CompleteMultipartUploadResult />")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-ccmhz",
               "NRH03s0Zi0/original",
               "eu",
               "mave-upload",
               "uploads/source.mp4",
               "fr-par",
               part_concurrency: 1,
               part_size: configured_part_size,
               multipart_max_parts: 2,
               server_side_copy?: false,
               single_put_max_bytes: configured_part_size - 1
             )
  end

  test "copy_public_between_profiles transfers multipart ranges concurrently and completes them in order" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "eu" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    part_size = 5 * 1024 * 1024
    source_body = :binary.copy("a", part_size) <> "tail"
    source_size = byte_size(source_body)
    test_pid = self()

    expected_parts = %{
      "1" => binary_part(source_body, 0, part_size),
      "2" => binary_part(source_body, part_size, 4)
    }

    expected_ranges = %{
      "bytes=0-5242879" => Map.fetch!(expected_parts, "1"),
      "bytes=5242880-5242883" => Map.fetch!(expected_parts, "2")
    }

    Req.Test.stub(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      case {conn.method, conn.request_path, conn.query_params} do
        {"HEAD", "/mave-upload/uploads/source.mp4", _query_params} ->
          conn
          |> put_resp_header("content-length", Integer.to_string(source_size))
          |> put_resp_header("content-type", "video/mp4")
          |> send_resp(200, "")

        {"POST", "/space-ccmhz/NRH03s0Zi0/original", %{"uploads" => ""}} ->
          send_resp(
            conn,
            200,
            "<InitiateMultipartUploadResult><UploadId>upload-concurrent</UploadId></InitiateMultipartUploadResult>"
          )

        {"GET", "/mave-upload/uploads/source.mp4", _query_params} ->
          [range] = get_req_header(conn, "range")
          body = Map.fetch!(expected_ranges, range)
          send(test_pid, {:range_started, range, self()})

          receive do
            :release_range ->
              conn
              |> put_resp_header("content-type", "application/octet-stream")
              |> send_resp(206, body)
          after
            5_000 ->
              send_resp(conn, 504, "")
          end

        {"PUT", "/space-ccmhz/NRH03s0Zi0/original",
         %{
           "partNumber" => part_number,
           "uploadId" => "upload-concurrent"
         }} ->
          assert Req.Test.raw_body(conn) == Map.fetch!(expected_parts, part_number)

          conn
          |> put_resp_header("etag", ~s("etag-#{part_number}"))
          |> send_resp(200, "")

        {"POST", "/space-ccmhz/NRH03s0Zi0/original",
         %{
           "uploadId" => "upload-concurrent"
         }} ->
          send(test_pid, {:multipart_completed, Req.Test.raw_body(conn)})
          send_resp(conn, 200, "<CompleteMultipartUploadResult />")

        request ->
          send(test_pid, {:unexpected_request, request})
          send_resp(conn, 500, "")
      end
    end)

    task_supervisor = start_supervised!(Task.Supervisor)

    copy_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Storage.copy_public_between_profiles(
          "space-ccmhz",
          "NRH03s0Zi0/original",
          "eu",
          "mave-upload",
          "uploads/source.mp4",
          "fr-par",
          part_concurrency: 2,
          server_side_copy?: false,
          part_size: part_size,
          single_put_max_bytes: part_size - 1
        )
      end)

    assert_receive {:range_started, first_range, first_request}, 2_000
    assert_receive {:range_started, second_range, second_request}, 2_000
    assert MapSet.new([first_range, second_range]) == MapSet.new(Map.keys(expected_ranges))

    send(second_request, :release_range)
    send(first_request, :release_range)

    assert :ok = Task.await(copy_task, 10_000)
    assert_receive {:multipart_completed, completion_body}

    assert completion_body =~
             "<PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag>"

    assert completion_body =~
             "<PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag>"

    refute_receive {:unexpected_request, _request}
  end

  test "copy_public_between_profiles retries transient multipart part failures" do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    Application.put_env(:mave_core, :storage_providers, %{
      "fr-par" => [
        access_key_id: "source-key",
        secret_access_key: "source-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ],
      "eu" => [
        access_key_id: "dest-key",
        secret_access_key: "dest-secret",
        endpoint: "https://storage.example.test",
        region: "fr-par"
      ]
    })

    part_size = 5 * 1024 * 1024
    source_body = :binary.copy("a", part_size) <> "tail"
    part_1 = binary_part(source_body, 0, part_size)
    part_2 = binary_part(source_body, part_size, 4)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "HEAD"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"

      conn
      |> put_resp_header("content-length", Integer.to_string(byte_size(source_body)))
      |> put_resp_header("content-type", "video/mp4")
      |> send_resp(200, "")
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_string == "uploads"

      send_resp(
        conn,
        200,
        "<InitiateMultipartUploadResult><UploadId>upload-123</UploadId></InitiateMultipartUploadResult>"
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"
      assert get_req_header(conn, "range") == ["bytes=0-5242879"]

      Req.Test.transport_error(conn, :timeout)
    end)

    expect_range_get("bytes=0-5242879", part_1)
    expect_part_upload("1", part_1, ~s("etag-1"))
    expect_range_get("bytes=5242880-5242883", part_2)
    expect_part_upload("2", part_2, ~s("etag-2"))

    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_params["uploadId"] == "upload-123"

      body = Req.Test.raw_body(conn)
      assert body =~ "<PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag>"
      assert body =~ "<PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag>"

      send_resp(conn, 200, "<CompleteMultipartUploadResult />")
    end)

    assert :ok =
             Storage.copy_public_between_profiles(
               "space-ccmhz",
               "NRH03s0Zi0/original",
               "eu",
               "mave-upload",
               "uploads/source.mp4",
               "fr-par",
               part_concurrency: 1,
               part_attempts: 2,
               part_size: part_size,
               server_side_copy?: false,
               single_put_max_bytes: part_size - 1
             )
  end

  test "build_allowed_origins includes base domain dashboard hosts" do
    Application.put_env(:mave_core, :domain, "https://mave.io")

    origins = Storage.build_allowed_origins([])

    assert "https://mave.io" in origins
    assert "http://mave.io" in origins
    assert "https://app.mave.io" in origins
    assert "https://dash.mave.io" in origins
  end

  test "build_allowed_origins includes related staging dashboard hosts" do
    Application.put_env(:mave_core, :domain, "https://api.staging.mave.io")

    origins = Storage.build_allowed_origins(["example.com"])

    assert "https://api.staging.mave.io" in origins
    assert "https://staging.mave.io" in origins
    assert "https://app.staging.mave.io" in origins
    assert "https://dash.staging.mave.io" in origins
  end

  test "build_allowed_origins permits configured domains and their descendants" do
    origins = Storage.build_allowed_origins(["mave.io", "app.customer.example"])

    assert "https://mave.io" in origins
    assert "https://*.mave.io" in origins
    assert "http://mave.io" in origins
    assert "http://*.mave.io" in origins
    assert "https://app.customer.example" in origins
    assert "https://*.app.customer.example" in origins
    refute "https://*.customer.example" in origins
  end

  test "build_bucket_cors_xml uses wildcard-only rule when open" do
    xml = Storage.build_bucket_cors_xml(["*"])

    assert xml =~ "<AllowedOrigin>*</AllowedOrigin>"
    assert xml =~ "<ExposeHeader>Accept-Ranges</ExposeHeader>"
    assert xml =~ "<ExposeHeader>Content-Range</ExposeHeader>"
    refute xml =~ "<AllowedOrigin>https://video-dns.com</AllowedOrigin>"
  end

  test "sync_space_domain_cors keeps the shared trial bucket public" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 3, fn conn ->
      case {conn.method, conn.request_path, conn.query_string} do
        {"HEAD", "/space-trial", ""} ->
          send_resp(conn, 200, "")

        {"PUT", "/space-trial", "cors"} ->
          body = Req.Test.raw_body(conn)
          assert body =~ "<AllowedOrigin>*</AllowedOrigin>"
          refute body =~ "example.com"
          send_resp(conn, 200, "")

        {"PUT", "/space-trial", "policy"} ->
          policy = conn |> Req.Test.raw_body() |> Jason.decode!()

          assert get_in(policy, ["Statement", Access.at(0), "Sid"]) ==
                   "AllowPublicReadGetObject"

          refute get_in(policy, ["Statement", Access.at(0), "Condition"])
          send_resp(conn, 200, "")
      end
    end)

    space = %Space{
      hash: "trial",
      region: "eu_3",
      hotlink_protection_enabled: true,
      domains: [%Domain{domain: "example.com"}]
    }

    assert :ok = Storage.sync_space_domain_cors(space)
  end

  test "sync_space_domain_cors permits every configured domain and its descendants" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, 3, fn conn ->
      case {conn.method, conn.request_path, conn.query_string} do
        {"HEAD", "/space-multi", ""} ->
          send_resp(conn, 200, "")

        {"PUT", "/space-multi", "cors"} ->
          body = Req.Test.raw_body(conn)
          assert body =~ "<AllowedOrigin>https://mave.io</AllowedOrigin>"
          assert body =~ "<AllowedOrigin>https://*.mave.io</AllowedOrigin>"
          assert body =~ "<AllowedOrigin>https://app.customer.example</AllowedOrigin>"
          assert body =~ "<AllowedOrigin>https://*.app.customer.example</AllowedOrigin>"
          refute body =~ "<AllowedOrigin>https://*.customer.example</AllowedOrigin>"
          send_resp(conn, 200, "")

        {"PUT", "/space-multi", "policy"} ->
          policy = conn |> Req.Test.raw_body() |> Jason.decode!()

          referers =
            get_in(policy, [
              "Statement",
              Access.at(0),
              "Condition",
              "StringLike",
              "aws:Referer"
            ])

          assert "https://mave.io/*" in referers
          assert "https://*.mave.io/*" in referers
          assert "https://app.customer.example/*" in referers
          assert "https://*.app.customer.example/*" in referers
          refute "https://*.customer.example/*" in referers
          send_resp(conn, 200, "")
      end
    end)

    space = %Space{
      hash: "multi",
      region: "eu_3",
      hotlink_protection_enabled: true,
      domains: [
        %Domain{domain: "mave.io"},
        %Domain{domain: "app.customer.example"}
      ]
    }

    assert :ok = Storage.sync_space_domain_cors(space)
  end

  test "build_bucket_policy_json includes referer patterns" do
    policy =
      Storage.build_bucket_policy_json("space-test", [
        "example.com",
        "https://dash.staging.mave.io"
      ])
      |> Jason.decode!()

    referers =
      get_in(policy, ["Statement", Access.at(0), "Condition", "StringLike", "aws:Referer"])

    assert policy["Version"] == "2012-10-17"
    assert get_in(policy, ["Statement", Access.at(0), "Resource"]) == "arn:aws:s3:::space-test/*"
    assert "https://example.com" in referers
    assert "https://example.com/*" in referers
    assert "https://*.example.com" in referers
    assert "https://*.example.com/*" in referers
    assert "https://dash.staging.mave.io" in referers
    assert "https://dash.staging.mave.io/*" in referers
    assert "https://*.dash.staging.mave.io" in referers
    assert "https://*.dash.staging.mave.io/*" in referers
    refute "https://*.staging.mave.io/*" in referers
    assert "http://localhost:*" in referers
    assert "http://localhost:*/*" in referers

    assert get_in(policy, ["Statement", Access.at(1), "Sid"]) == "AllowMaveFfmpegRead"

    assert get_in(policy, [
             "Statement",
             Access.at(1),
             "Condition",
             "StringLike",
             "aws:Referer"
           ]) == Storage.ffmpeg_input_referer()
  end

  test "ensure_ffmpeg_bucket_access_policy preserves existing statements" do
    Req.default_options(plug: {Req.Test, __MODULE__})
    bucket = "mave-upload-#{System.unique_integer([:positive])}"

    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.fr-par.scw.cloud",
      region: "fr-par"
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/#{bucket}"
      assert conn.query_string == "policy"

      send_resp(
        conn,
        200,
        Jason.encode!(%{
          "Policy" =>
            Jason.encode!(%{
              "Version" => "2023-04-17",
              "Statement" => [
                %{
                  "Sid" => "KeepMe",
                  "Effect" => "Allow",
                  "Principal" => %{"SCW" => "user_id:existing-writer"},
                  "Action" => "s3:PutObject",
                  "Resource" => ["#{bucket}/existing/*"]
                }
              ]
            })
        })
      )
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/#{bucket}"
      assert conn.query_string == "policy"

      policy = conn |> Req.Test.raw_body() |> Jason.decode!()
      assert policy["Version"] == "2023-04-17"
      refute Map.has_key?(policy, "Policy")
      assert Enum.any?(policy["Statement"], &(Map.get(&1, "Sid") == "KeepMe"))

      assert Enum.any?(policy["Statement"], fn statement ->
               statement["Sid"] == "AllowMaveFfmpegRead" and
                 statement["Resource"] == ["#{bucket}/*"] and
                 get_in(statement, ["Condition", "StringLike", "aws:Referer"]) ==
                   Storage.ffmpeg_input_referer()
             end)

      send_resp(conn, 200, "")
    end)

    assert :ok = Storage.ensure_ffmpeg_bucket_access_policy(bucket, nil)
    assert :ok = Storage.ensure_ffmpeg_bucket_access_policy(bucket, nil)
  end

  test "ensure_ffmpeg_bucket_access_policy does not lock a Scaleway bucket without a writer" do
    Req.default_options(plug: {Req.Test, __MODULE__})
    bucket = "mave-upload-no-writer-#{System.unique_integer([:positive])}"

    Application.put_env(:mave_core, :s3,
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      endpoint: "https://s3.fr-par.scw.cloud",
      region: "fr-par"
    )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/#{bucket}"
      assert conn.query_string == "policy"
      send_resp(conn, 404, "")
    end)

    assert {:error, :scaleway_bucket_policy_writer_required} =
             Storage.ensure_ffmpeg_bucket_access_policy(bucket, nil)
  end

  test "build_public_bucket_policy_json allows public object reads" do
    policy =
      Storage.build_public_bucket_policy_json("space-test")
      |> Jason.decode!()

    assert policy["Version"] == "2012-10-17"
    assert get_in(policy, ["Statement", Access.at(0), "Sid"]) == "AllowPublicReadGetObject"
    assert get_in(policy, ["Statement", Access.at(0), "Action"]) == "s3:GetObject"

    assert get_in(policy, ["Statement", Access.at(0), "Resource"]) ==
             "arn:aws:s3:::space-test/*"

    refute get_in(policy, ["Statement", Access.at(0), "Condition"])
  end

  defp expect_range_get(range, body) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/mave-upload/uploads/source.mp4"
      assert get_req_header(conn, "range") == [range]

      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> send_resp(206, body)
    end)
  end

  defp expect_part_upload(part_number, body, etag) do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "PUT"
      assert conn.request_path == "/space-ccmhz/NRH03s0Zi0/original"
      assert conn.query_params["partNumber"] == part_number
      assert conn.query_params["uploadId"] == "upload-123"
      assert Req.Test.raw_body(conn) == body

      conn
      |> put_resp_header("etag", etag)
      |> send_resp(200, "")
    end)
  end

  defp expect_part_copy(part_number, range, etag) do
    Req.Test.expect(__MODULE__, fn conn ->
      conn = fetch_query_params(conn)

      assert conn.method == "PUT"
      assert conn.request_path == "/space-mett/NRH03s0Zi0/original"
      assert conn.query_params["partNumber"] == part_number
      assert conn.query_params["uploadId"] == "upload-123"
      assert get_req_header(conn, "x-amz-copy-source") == ["/mave-upload/uploads/source.mp4"]
      assert get_req_header(conn, "x-amz-copy-source-range") == [range]
      assert Req.Test.raw_body(conn) == ""

      send_resp(conn, 200, "<CopyPartResult><ETag>#{etag}</ETag></CopyPartResult>")
    end)
  end
end
