# Executed only by smoke.sh inside its disposable release container.
defmodule MaveCore.SelfHostedSmoke do
  @moduledoc false
  import Ecto.Query

  alias MaveCore.Accounts
  alias MaveCore.Accounts.User
  alias MaveCore.Flow.Run
  alias MaveCore.Media.Manifest
  alias MaveCore.Repo
  alias MaveCore.Spaces

  @origin "http://localhost"
  @transport "http://caddy"
  @fixture "/tmp/mave-core-smoke.mp4"

  def run do
    check(
      Regex.match?(~r/^mave-core-smoke-[a-f0-9]{12}$/, System.get_env("MAVE_SMOKE_RUN_ID", "")),
      "Refusing to run outside an isolated smoke installation"
    )

    check(Application.fetch_env!(:mave_core, :domain) == @origin, "Unexpected smoke origin")
    check(Repo.aggregate(User, :count) == 0, "Refusing to run against existing account data")
    request(:get, "/health", 200)
    key = bootstrap()
    auth = [{"authorization", "Bearer " <> Spaces.display_api_key(key.key, key.secret)}]
    video = api_roundtrip(auth)
    generate_fixture()
    upload(video["id"], key)
    wait_for_processing(video["id"], auth)
    playback(video["id"])
    analytics(video["id"], auth)
    IO.puts("PASS: self-hosted protocol journey")
  end

  defp bootstrap do
    {:ok, owner} = MaveCore.Release.bootstrap_owner("smoke@example.com")
    check(owner.created?, "Bootstrap did not create a fresh owner")
    login_uri = URI.parse(owner.login_url)
    response = request(:get, login_uri.path <> "?" <> login_uri.query, 302)

    cookie =
      response
      |> Req.Response.get_header("set-cookie")
      |> Enum.map_join("; ", &(&1 |> String.split(";", parts: 2) |> hd()))

    check(cookie != "", "Login did not issue a session cookie")
    request(:get, "/videos", 200, headers: [{"cookie", cookie}])
    user = Accounts.get_user_by_email(owner.email)
    {:ok, key} = Spaces.create_key(user.current_space_membership.space, %{description: "Smoke"})
    IO.puts("PASS: first-owner bootstrap and HTTP login")
    key
  end

  defp api_roundtrip(auth) do
    request(:get, "/api/v1/videos", 401)

    created =
      request(:post, "/api/v1/videos", 200, headers: auth, json: %{name: "Smoke draft"}).body

    check(is_binary(created["id"]), "API create did not return a video ID")
    path = "/api/v1/videos/" <> created["id"]
    updated = request(:put, path, 200, headers: auth, json: %{name: "Smoke upload"}).body
    check(updated["name"] == "Smoke upload", "API update did not persist the name")
    check(request(:get, path, 200, headers: auth).body["id"] == created["id"], "API read failed")
    IO.puts("PASS: API authentication, create, read and update")
    updated
  end

  defp generate_fixture do
    command!("ffmpeg", [
      "-hide_banner",
      "-loglevel",
      "error",
      "-nostdin",
      "-y",
      "-f",
      "lavfi",
      "-i",
      "testsrc2=size=640x360:rate=24",
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=880:sample_rate=48000",
      "-t",
      "4",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-shortest",
      @fixture
    ])
  end

  defp upload(public_id, key) do
    bytes = File.read!(@fixture)
    tus_headers = [{"tus-resumable", "1.0.0"}]

    # Exercise the actual tusd pre-create hook, not a direct call into Uploads.
    rejected = request(:post, "/files", nil, headers: tus_headers ++ [{"upload-length", "1"}])
    check(rejected.status in 400..499, "tusd accepted an upload without a signed token")

    metadata =
      %{
        "token" => MaveCore.Uploads.Token.sign_api_key(key, public_id),
        "upload_id" => Ecto.UUID.generate(),
        "filename" => "smoke.mp4",
        "filetype" => "video/mp4",
        "title" => "Smoke upload"
      }
      |> Enum.map_join(",", fn {name, value} -> name <> " " <> Base.encode64(value) end)

    created =
      request(:post, "/files", 201,
        headers:
          tus_headers ++
            [{"upload-length", to_string(byte_size(bytes))}, {"upload-metadata", metadata}]
      )

    [location] = Req.Response.get_header(created, "location")
    upload_uri = URI.merge(@origin <> "/files", location)

    check(
      upload_uri.host == "localhost" and upload_uri.scheme == "http" and upload_uri.port == 80,
      "Unexpected tus upload origin"
    )

    request(:patch, upload_uri.path, 204,
      headers:
        tus_headers ++
          [{"upload-offset", "0"}, {"content-type", "application/offset+octet-stream"}],
      body: bytes
    )

    head = request(:head, upload_uri.path, 200, headers: tus_headers)

    check(
      Req.Response.get_header(head, "upload-offset") == [to_string(byte_size(bytes))],
      "Incomplete tus upload"
    )

    IO.puts("PASS: signed tus upload and upload offset")
  end

  defp wait_for_processing(public_id, auth) do
    <<_space_hash::binary-size(5), embed_hash::binary-size(10)>> = public_id

    wait_for("video processing", 300_000, fn ->
      statuses =
        Repo.all(
          from run in Run,
            where: fragment("?->>'embed_hash' = ?", run.input, ^embed_hash),
            select: run.status
        )

      check(
        not Enum.any?(statuses, &(&1 in ["failed", "cancelled"])),
        "Media flow failed; inspect private service logs"
      )

      if statuses != [] and Enum.all?(statuses, &(&1 == "succeeded")) do
        video = request(:get, "/api/v1/videos/" <> public_id, 200, headers: auth).body
        check(video["width"] == 640 and video["height"] == 360, "Wrong processed dimensions")

        check(
          is_number(video["duration"]) and video["duration"] >= 3.5,
          "Wrong processed duration"
        )

        {:ok, video}
      else
        :retry
      end
    end)

    IO.puts("PASS: real media flow completed with expected video metadata")
  end

  defp playback(public_id) do
    <<space_hash::binary-size(5), embed_hash::binary-size(10)>> = public_id
    storage = "/storage/space-" <> space_hash <> "/"
    manifest_json = request(:get, storage <> embed_hash <> "/manifest.json", 200).body
    {:ok, manifest} = Manifest.parse(manifest_json)
    check(manifest.id == public_id, "Manifest does not match the uploaded video")
    asset_base = Manifest.asset_base_path(embed_hash, manifest)
    playlist = storage <> asset_base <> "/playlist.m3u8"
    request(:get, playlist, 200)
    waveform = request(:get, storage <> asset_base <> "/audio_peaks.json", 200).body

    check(
      is_list(waveform["peaks"]) and
        Enum.any?(waveform["peaks"], &(is_number(&1) and &1 > 0)),
      "Missing measured audio peaks"
    )

    player = request(:get, storage <> embed_hash <> "/player.html", 200).body

    check(
      is_binary(player) and String.contains?(player, "mave-player"),
      "Missing generated player"
    )

    request(:get, "/storage/mave-upload/", 403)

    # Decode the public HLS video AND audio, rather than only checking HTTP 200.
    output =
      command!("ffmpeg", [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-xerror",
        "-headers",
        "Host: localhost\r\n",
        "-i",
        @transport <> playlist,
        "-map",
        "0:v:0",
        "-map",
        "0:a:0",
        "-progress",
        "pipe:1",
        "-f",
        "null",
        "-"
      ])

    check(String.contains?(output, "progress=end"), "HLS decoding did not finish")
    [_, frames] = output |> then(&Regex.scan(~r/frame=(\d+)/, &1)) |> List.last()
    check(String.to_integer(frames) >= 90, "HLS did not decode the complete video")
    IO.puts("PASS: public manifest/player, full HLS decode and private upload bucket")
  end

  defp analytics(public_id, auth) do
    now = System.system_time(:millisecond)
    session_id = Ecto.UUID.generate()

    events =
      for {name, timestamp, position} <- [{"play", now - 2_000, 0.0}, {"pause", now, 2.0}] do
        %{
          name: name,
          timestamp: timestamp,
          video_time: position,
          duration: 4,
          session_id: session_id,
          embed_id: public_id,
          component: "self-hosted-smoke",
          source_url: "http://localhost/smoke-playback"
        }
      end

    request(:post, "/v1/events", 202, json: %{events: events})

    wait_for("analytics readback", 60_000, fn ->
      data = request(:get, "/api/v1/videos/" <> public_id <> "/data", 200, headers: auth).body

      if get_in(data, ["data", "views", "year"]) == 1 do
        {:ok, data}
      else
        :retry
      end
    end)

    IO.puts("PASS: metrics ingestion and analytics API readback")
  end

  defp request(method, path, status, opts \\ []) do
    # Exercise the normal localhost HTTP configuration through the real ingress.
    opts = Keyword.update(opts, :headers, [{"host", "localhost"}], &[{"host", "localhost"} | &1])

    opts =
      Keyword.merge(
        [
          method: method,
          url: @transport <> path,
          retry: false,
          redirect: false,
          receive_timeout: 15_000
        ],
        opts
      )

    case Req.request(opts) do
      {:ok, response} ->
        check(
          is_nil(status) or response.status == status,
          "Unexpected HTTP status #{response.status} (expected #{status}) for #{method}"
        )

        response

      {:error, _reason} ->
        raise "HTTP transport failed during smoke test"
    end
  end

  defp command!(executable, args) do
    {output, status} = System.cmd("timeout", ["60", executable | args], stderr_to_stdout: true)
    check(status == 0, "#{executable} failed (exit #{status})")
    output
  end

  defp wait_for(label, timeout, check_fn) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(label, deadline, check_fn)
  end

  defp poll(label, deadline, check_fn) do
    case check_fn.() do
      {:ok, result} ->
        result

      :retry ->
        check(System.monotonic_time(:millisecond) < deadline, "Timed out waiting for #{label}")

        receive do
        after
          1_000 -> poll(label, deadline, check_fn)
        end
    end
  end

  defp check(true, _message), do: :ok
  defp check(false, message), do: raise(message)
end

MaveCore.SelfHostedSmoke.run()
