defmodule MaveCore.Workers.ImageProcessorTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias MaveCore.Media.{Manifest, Storage}
  alias MaveCore.TestSupport.{BusyImageGenerationCoordinator, FlowStorageAdapterStub}
  alias MaveCore.Workers.ImageProcessor

  defmodule ClaimingImageGenerationCoordinator do
    @moduledoc false

    def claim(_key, _ttl_ms), do: {:ok, "image-owner"}
    def release(_key, "image-owner"), do: :ok
  end

  defmodule TimeoutFlameCaller do
    @moduledoc false

    def call(pool, _fun) do
      send(self(), {:image_flame_pool, pool})
      exit(:timeout)
    end
  end

  defmodule PermissiveImageVariantBudget do
    @moduledoc false

    def reserve(_space_hash, _embed_hash, _output_path), do: {:ok, :existing}
  end

  setup do
    original = Application.get_env(:mave_core, :image_variant_budget_module)
    Application.put_env(:mave_core, :image_variant_budget_module, PermissiveImageVariantBudget)

    on_exit(fn -> restore_env(:image_variant_budget_module, original) end)
  end

  test "cache_output_path uses the current manifest version" do
    assert ImageProcessor.cache_output_path("abc123", %Manifest{video: %{version: 0}}, 4.0,
             width: 50
           ) ==
             "abc123/_images/abc123_4.0_w50.jpg"

    assert ImageProcessor.cache_output_path("abc123", %Manifest{video: %{version: 2}}, 4.0,
             width: 50
           ) ==
             "abc123/_images/v2/abc123_4.0_w50.jpg"
  end

  test "process/4 returns not found without FLAME when the source playlist is missing" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      if is_nil(original_storage_module) do
        Application.delete_env(:mave_core, :storage_module)
      else
        Application.put_env(:mave_core, :storage_module, original_storage_module)
      end
    end)

    space_hash = "fast1"
    embed_hash = "NoSource01"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)

    manifest_json =
      Jason.encode!(%{
        video: %{version: 1}
      })

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               manifest_json,
               "application/json",
               region
             )

    log =
      capture_log([level: :info], fn ->
        assert {:error, :not_found} =
                 ImageProcessor.process(space_hash, embed_hash, 0.0, format: "webp")
      end)

    assert log =~ "Skipping image generation for #{space_hash}/#{embed_hash}"
    refute log =~ "generating via FLAME"
    refute log =~ "Starting image generation"
  end

  test "process/4 waits instead of spawning FLAME when generation is already in progress" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)

    original_coordinator_module =
      Application.get_env(:mave_core, :image_generation_coordinator_module)

    original_singleflight = Application.get_env(:mave_core, :image_generation_singleflight)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)

    Application.put_env(
      :mave_core,
      :image_generation_coordinator_module,
      BusyImageGenerationCoordinator
    )

    Application.put_env(:mave_core, :image_generation_singleflight,
      lock_ttl_ms: 1_000,
      wait_timeout_ms: 1,
      wait_poll_ms: 1
    )

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      restore_env(:image_generation_coordinator_module, original_coordinator_module)
      restore_env(:image_generation_singleflight, original_singleflight)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "InFlight01"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)

    manifest_json =
      Jason.encode!(%{
        video: %{version: 1}
      })

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               manifest_json,
               "application/json",
               region
             )

    put_test_playlists(bucket, embed_hash, region)

    log =
      capture_log([level: :info], fn ->
        assert {:error, :generation_in_progress} =
                 ImageProcessor.process(space_hash, embed_hash, 0.0, format: "webp")
      end)

    assert log =~ "Timed out waiting for in-flight image generation"
    refute log =~ "Starting image generation"
    refute log =~ "claimed image generation via FLAME"
  end

  test "process/4 returns generation in progress when image FLAME checkout times out" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)

    original_coordinator_module =
      Application.get_env(:mave_core, :image_generation_coordinator_module)

    original_flame_caller = Application.get_env(:mave_core, :image_flame_caller)
    original_image_flame_pool = Application.get_env(:mave_core, :image_flame_pool)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    Application.put_env(:mave_core, :image_flame_caller, TimeoutFlameCaller)
    Application.put_env(:mave_core, :image_flame_pool, MaveCore.Workers.ImageFlameRunner)

    Application.put_env(
      :mave_core,
      :image_generation_coordinator_module,
      ClaimingImageGenerationCoordinator
    )

    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      restore_env(:image_generation_coordinator_module, original_coordinator_module)
      restore_env(:image_flame_caller, original_flame_caller)
      restore_env(:image_flame_pool, original_image_flame_pool)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "Timeout01"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)

    manifest_json =
      Jason.encode!(%{
        video: %{version: 1}
      })

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               manifest_json,
               "application/json",
               region
             )

    put_test_playlists(bucket, embed_hash, region)

    log =
      capture_log([level: :warning], fn ->
        assert {:error, :generation_in_progress} =
                 ImageProcessor.process(space_hash, embed_hash, 0.0, format: "webp", width: 100)
      end)

    assert log =~ "Image generation via FLAME timed out"
    assert_received {:image_flame_pool, MaveCore.Workers.ImageFlameRunner}
  end

  test "process/4 serves existing thumbnail for default poster requests before FLAME" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)

    Application.put_env(:mave_core, :storage_module, FlowStorageAdapterStub)
    FlowStorageAdapterStub.reset!()

    on_exit(fn ->
      restore_env(:storage_module, original_storage_module)
      FlowStorageAdapterStub.reset!()
    end)

    space_hash = "fast1"
    embed_hash = "Thumb01"
    region = MaveCore.Spaces.get_region(space_hash)
    bucket = FlowStorageAdapterStub.bucket_for_space(space_hash, region)
    thumbnail_data = "existing webp thumbnail"

    manifest_json =
      Jason.encode!(%{
        video: %{version: 1}
      })

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/manifest.json",
               manifest_json,
               "application/json",
               region
             )

    assert {:ok, _} =
             FlowStorageAdapterStub.put_public(
               bucket,
               "#{embed_hash}/thumbnail.webp",
               thumbnail_data,
               "image/webp",
               region
             )

    output_path = "#{embed_hash}/_images/v1/#{embed_hash}_0.0.webp"

    assert {:ok, ^output_path, ^thumbnail_data} =
             ImageProcessor.process(space_hash, embed_hash, 0.0, format: "webp")

    assert {:ok, ^thumbnail_data} = FlowStorageAdapterStub.get(bucket, output_path, region)
    assert FlowStorageAdapterStub.public?(bucket, output_path, region)
  end

  @tag :integration
  test "process/4 generates image data successfully" do
    original_storage_module = Application.get_env(:mave_core, :storage_module)
    Application.put_env(:mave_core, :storage_module, Storage)

    on_exit(fn -> restore_env(:storage_module, original_storage_module) end)

    space = "ubg50"
    embed = "LeDE9v86ye"
    time = 4.0

    {:ok, path, data} = ImageProcessor.process(space, embed, time, width: 50)

    assert is_binary(path)
    assert is_binary(data)
    assert byte_size(data) > 0
    assert String.ends_with?(path, ".jpg")
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp put_test_playlists(bucket, embed_hash, region) do
    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/v1/playlist.m3u8",
               "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720\n720p/playlist.m3u8\n",
               "application/vnd.apple.mpegurl",
               region
             )

    assert {:ok, _} =
             FlowStorageAdapterStub.put(
               bucket,
               "#{embed_hash}/v1/720p/playlist.m3u8",
               "#EXTM3U\n#EXTINF:4.500000,\nsegment0.m4s\n#EXT-X-ENDLIST\n",
               "application/vnd.apple.mpegurl",
               region
             )
  end
end
