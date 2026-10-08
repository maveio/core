defmodule MaveCore.Media.ManifestTest do
  use ExUnit.Case, async: true
  alias MaveCore.Media.Manifest

  describe "parse/1" do
    test "parses valid JSON string" do
      json = ~s({"id": "123", "name": "Test Video"})
      assert {:ok, %Manifest{id: "123", name: "Test Video"}} = Manifest.parse(json)
    end

    test "parses map" do
      data = %{id: "123", name: "Test Video"}
      assert {:ok, %Manifest{id: "123", name: "Test Video"}} = Manifest.parse(data)
    end

    test "parses decoded JSON maps with string keys" do
      data = %{
        "id" => "123",
        "name" => "Test Video",
        "video" => %{"version" => 4}
      }

      assert {:ok, %Manifest{id: "123", name: "Test Video"} = manifest} =
               Manifest.parse(data)

      assert Manifest.asset_base_path("abc123", manifest) == "abc123/v4"
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = Manifest.parse("invalid json")
    end
  end

  describe "asset_base_path/2" do
    test "returns embed_hash when version is 0" do
      manifest = %Manifest{video: %{version: 0}}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123"
    end

    test "returns embed_hash/vN when version > 0" do
      manifest = %Manifest{video: %{version: 1}}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123/v1"

      manifest = %Manifest{video: %{version: 8}}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123/v8"
    end

    test "returns embed_hash when version is nil" do
      manifest = %Manifest{video: %{version: nil}}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123"
    end

    test "returns embed_hash when video has no version key" do
      manifest = %Manifest{video: %{}}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123"
    end

    test "returns embed_hash when video is nil" do
      manifest = %Manifest{video: nil}
      assert Manifest.asset_base_path("abc123", manifest) == "abc123"
    end
  end
end
