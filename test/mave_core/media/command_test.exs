defmodule MaveCore.Media.CommandTest do
  use ExUnit.Case, async: false

  alias MaveCore.Media.Command

  setup do
    keys = ~w(PATH MAVE_MEDIA_SANDBOX AWS_SECRET_ACCESS_KEY DATABASE_URL LD_PRELOAD)
    original = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "removes credentials and dynamic loader hooks even without Linux sandboxing" do
    System.put_env("AWS_SECRET_ACCESS_KEY", "private")
    System.put_env("DATABASE_URL", "private")
    System.put_env("LD_PRELOAD", "/private.so")
    environment = Map.new(Command.environment())
    assert environment["AWS_SECRET_ACCESS_KEY"] == nil
    assert environment["DATABASE_URL"] == nil
    assert environment["LD_PRELOAD"] == nil
    assert environment["PATH"] == System.get_env("PATH")
  end

  test "required sandboxing fails closed when the launcher is missing" do
    System.put_env("MAVE_MEDIA_SANDBOX", "required")
    System.put_env("PATH", "/nonexistent")

    assert {:error, :media_sandbox_not_found} =
             Command.prepare("/usr/bin/ffmpeg", [], "/tmp/mave-flow")

    System.put_env("MAVE_MEDIA_SANDBOX", "typo")

    assert {:error, :invalid_media_sandbox_mode} =
             Command.prepare("/usr/bin/ffmpeg", [], "/tmp/mave-flow")
  end

  test "limits protocols for ffmpeg and ffprobe without replacing explicit stricter limits" do
    System.put_env("MAVE_MEDIA_SANDBOX", "disabled")

    assert {:ok, _, args} =
             Command.prepare("/usr/bin/ffmpeg", ["-i", "video.mp4"], "/tmp/mave-flow")

    assert "-nostdin" in args
    assert "-protocol_whitelist" in args

    assert {:ok, _, args} =
             Command.prepare(
               "/usr/bin/ffprobe",
               ["-protocol_whitelist", "file"],
               "/tmp/mave-flow"
             )

    assert args == ["-protocol_whitelist", "file"]
  end

  test "applies protocol restrictions separately to every ffmpeg input" do
    System.put_env("MAVE_MEDIA_SANDBOX", "disabled")

    assert {:ok, _, args} =
             Command.prepare(
               "/usr/bin/ffmpeg",
               ["-protocol_whitelist", "file", "-i", "one.mp4", "-i", "two.mp4"],
               "/tmp/mave-flow"
             )

    assert Enum.count(args, &(&1 == "-protocol_whitelist")) == 2

    assert Enum.chunk_every(args, 3, 1, :discard)
           |> Enum.member?(["-protocol_whitelist", "file", "-i"])
  end

  test "grants only referenced scratch jobs and rejects paths escaping their root" do
    dir = Path.join(System.tmp_dir!(), "media-command-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    launcher = Path.join(dir, "mave-media-broker")
    File.write!(launcher, "#!/bin/sh\nexit 1\n")
    File.chmod!(launcher, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    System.put_env("PATH", dir)
    System.put_env("MAVE_MEDIA_SANDBOX", "required")

    assert {:ok, ^launcher, args} =
             Command.prepare(
               "/usr/bin/ffmpeg",
               [
                 "-i",
                 "/tmp/mave-flow/job/input.mp4",
                 "/tmp/mave-flow/job/output.mp4",
                 "/tmp/mave-flow/../../etc/passwd"
               ],
               "/tmp/mave-flow"
             )

    assert ["--scratch", "/tmp/mave-flow/job", "--", "/usr/bin/ffmpeg" | _] = args
    assert Enum.count(args, &(&1 == "--scratch")) == 1
  end
end
