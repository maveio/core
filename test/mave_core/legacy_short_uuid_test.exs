defmodule MaveCore.LegacyShortUUIDTest do
  use ExUnit.Case, async: true

  alias MaveCore.Ecto.LegacyShortUUID, as: EctoLegacyShortUUID
  alias MaveCore.LegacyShortUUID

  describe "encode/decode vectors" do
    test "matches known legacy vectors" do
      assert LegacyShortUUID.encode!("00000000-0000-0000-0000-000000000000") ==
               "2222222222222222222222"

      assert LegacyShortUUID.encode!("00000001-0001-0001-0001-000000000001") ==
               "UD6ibhr3V4YXvriP822222"

      assert LegacyShortUUID.decode!("UD6ibhr3V4YXvriP822222") ==
               "00000001-0001-0001-0001-000000000001"
    end

    test "roundtrips canonical uuid strings" do
      uuid = "2a162ee5-02f4-4701-9e87-72762cbce5e2"
      short = LegacyShortUUID.encode!(uuid)

      assert short == "keATfB8JP2ggT7U9JZrpV9"
      assert LegacyShortUUID.decode!(short) == uuid
      assert LegacyShortUUID.encode!(short) == short
    end

    test "rejects invalid inputs" do
      assert {:error, _reason} = LegacyShortUUID.decode("this-is-not-a-shortuuid")
      assert {:error, _reason} = LegacyShortUUID.encode("this-is-not-a-uuid")
    end
  end

  describe "ecto type compatibility" do
    test "cast, dump and load work with legacy encoding" do
      uuid = "2a162ee5-02f4-4701-9e87-72762cbce5e2"
      short = "keATfB8JP2ggT7U9JZrpV9"

      assert {:ok, ^short} = EctoLegacyShortUUID.cast(uuid)
      assert {:ok, ^short} = EctoLegacyShortUUID.cast(short)

      assert {:ok, uuid_binary} = EctoLegacyShortUUID.dump(short)
      assert byte_size(uuid_binary) == 16

      assert {:ok, ^short} = EctoLegacyShortUUID.load(uuid_binary)
    end
  end
end
