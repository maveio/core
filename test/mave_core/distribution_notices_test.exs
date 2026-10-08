defmodule MaveCore.DistributionNoticesTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("../..", __DIR__)
  @collector Path.join(@root, "deploy/licenses/collect.sh")

  setup %{tmp_dir: tmp_dir} do
    project = Path.join(tmp_dir, "project")

    files = %{
      "LICENSE" => "Core licence",
      "THIRD_PARTY_NOTICES.md" => "Core notices",
      "Dockerfile" => "FROM scratch",
      "mix.lock" => "%{}",
      "assets/package-lock.json" => "{}",
      "deps/ua_inspector/lib/ua_inspector/config.ex" => "  @remote_release \"6.5.0\"\n",
      "deploy/licenses/device-detector/VERSION" => "6.5.0\n",
      "deploy/licenses/device-detector/LICENSE" => "Data licence",
      "deploy/licenses/device-detector/NOTICE" => "Data attribution",
      "deps/example/LICENSE.md" => "Example licence",
      "deps/example/hex_metadata.config" => "Package metadata",
      "deps/example/native/Cargo.lock" => "Native dependency versions",
      "deps/example/third party/NOTICE" => "Nested attribution",
      "assets/node_modules/@scope/example/LICENSE.md" => "Browser licence",
      "deps/example/.git/NOTICE" => "Not a distributed file",
      "deps/example/target/NOTICE" => "Build cache",
      "deps/example/.env" => "Not a notice"
    }

    for {path, content} <- files do
      destination = Path.join(project, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, content)
    end

    %{project: project, output: Path.join(tmp_dir, "notices")}
  end

  test "collects notices and source metadata without path collisions", context do
    assert {"", 0} = collect(context)

    for path <- [
          "LICENSE",
          "THIRD_PARTY_NOTICES.md",
          "Dockerfile",
          "deps/example/LICENSE.md",
          "deps/example/hex_metadata.config",
          "deps/example/native/Cargo.lock",
          "deps/example/third party/NOTICE",
          "assets/node_modules/@scope/example/LICENSE.md"
        ] do
      assert File.read!(Path.join(context.output, path)) ==
               File.read!(Path.join(context.project, path))
    end

    assert File.read!(Path.join(context.output, "manifests/mix.lock")) == "%{}"
    assert File.read!(Path.join(context.output, "manifests/npm-package-lock.json")) == "{}"
    assert File.read!(Path.join(context.output, "data/device-detector/LICENSE")) == "Data licence"

    assert File.read!(Path.join(context.output, "data/device-detector/NOTICE")) ==
             "Data attribution"

    for path <- ["deps/example/.git", "deps/example/target", "deps/example/.env"] do
      refute File.exists?(Path.join(context.output, path))
    end
  end

  test "requires a data licence review when the dependency changes its data version", context do
    File.write!(
      Path.join(context.project, "deps/ua_inspector/lib/ua_inspector/config.ex"),
      "  @remote_release \"7.0.0\"\n"
    )

    assert {message, 1} = collect(context)
    assert message =~ "Review the Device Detector data licence"
    refute File.exists?(context.output)
  end

  test "fails if dependency notices cannot be inspected", context do
    File.rename!(
      Path.join(context.project, "assets/node_modules"),
      Path.join(context.project, "assets/unavailable")
    )

    assert {_message, status} = collect(context)
    assert status != 0
  end

  test "does not overwrite an existing output directory", context do
    File.mkdir_p!(context.output)
    sentinel = Path.join(context.output, "LICENSE")
    File.write!(sentinel, "Existing file")

    assert {message, 1} = collect(context)
    assert message =~ "OUTPUT_DIR must not exist"
    assert File.read!(sentinel) == "Existing file"
  end

  test "rejects relative output paths", context do
    assert {message, 1} = collect(%{context | output: "relative-notices"})
    assert message =~ "OUTPUT_DIR must be absolute"
  end

  test "README offers commercial licensing while the OSS image declares AGPL version 3 or later" do
    readme = File.read!(Path.join(@root, "README.md"))

    assert readme =~ "[AGPL-3.0-or-later](LICENSE)"
    assert readme =~ "Without a separate commercial agreement, the AGPL applies."
    assert readme =~ "[Contact us](https://www.mave.io/contact/)"

    assert File.read!(Path.join(@root, "Dockerfile")) =~
             ~s(org.opencontainers.image.licenses="AGPL-3.0-or-later")
  end

  test "Docker image retains notices and the verified FFmpeg source archive" do
    dockerfile = File.read!(Path.join(@root, "Dockerfile"))

    assert dockerfile =~ "cp COPYING* LICENSE.md /opt/ffmpeg/share/licenses/"

    assert dockerfile =~
             "cp /tmp/ffmpeg.tar.xz \"/opt/ffmpeg/share/source/ffmpeg-${FFMPEG_VERSION}.tar.xz\""

    assert dockerfile =~ "cp ffbuild/config.mak config.h /opt/ffmpeg/share/source/"
    assert dockerfile =~ "sh deploy/licenses/collect.sh /app /opt/mave-licenses"
    assert dockerfile =~ "COPY --from=builder /opt/mave-licenses /app/licenses"

    assert dockerfile =~
             "COPY --from=ffmpeg_builder /opt/ffmpeg/share/licenses/COPYING.GPLv3 " <>
               "/app/licenses/data/device-detector/COPYING"
  end

  defp collect(context) do
    System.cmd("sh", [@collector, context.project, context.output], stderr_to_stdout: true)
  end
end
