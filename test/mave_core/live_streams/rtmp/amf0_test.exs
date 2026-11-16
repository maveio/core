defmodule MaveCore.LiveStreams.RTMP.AMF0Test do
  use ExUnit.Case, async: true

  alias MaveCore.LiveStreams.RTMP.AMF0

  test "round-trips the values RTMP commands use" do
    values = ["connect", 1, %{"app" => "live", "flashVer" => "FMLE/3.0"}, nil, true, false]

    assert AMF0.decode(AMF0.encode(values)) ==
             {:ok,
              ["connect", 1.0, %{"app" => "live", "flashVer" => "FMLE/3.0"}, nil, true, false]}
  end

  test "keeps the property order of an ordered object" do
    encoded = AMF0.encode([{:object, [{"level", "status"}, {"code", "Start"}]}])

    assert encoded ==
             <<3, 0, 5, "level", 2, 0, 6, "status", 0, 4, "code", 2, 0, 5, "Start", 0, 0, 9>>
  end

  test "decodes the metadata an encoder sends as an ECMA array" do
    body =
      <<2, 0, 10, "onMetaData", 8, 0, 0, 0, 2, 0, 5, "width", 0, 1280.0::float-64, 0, 7,
        "encoder", 2, 0, 3, "obs", 0, 0, 9>>

    assert AMF0.decode(body) == {:ok, ["onMetaData", %{"width" => 1280.0, "encoder" => "obs"}]}
  end

  test "decodes strict arrays, long strings, dates and undefined" do
    body =
      <<0x0A, 0, 0, 0, 2, 0x01, 1, 0x06, 0x0C, 0, 0, 0, 2, "ok", 0x0B, 0::64, 0::16>>

    assert AMF0.decode(body) == {:ok, [[true, nil], "ok", nil]}
  end

  test "returns an error for truncated or unknown input" do
    assert AMF0.decode(<<2, 0, 10, "short">>) == :error
    assert AMF0.decode(<<3, 0, 3, "key">>) == :error
    assert AMF0.decode(<<0x7F>>) == :error
  end

  test "bounds nesting and the number of values" do
    nested = String.duplicate(<<3, 0, 1, "a">>, 20)
    assert AMF0.decode(nested) == :error

    assert AMF0.decode(String.duplicate(<<5>>, 256)) == {:ok, List.duplicate(nil, 256)}
    assert AMF0.decode(String.duplicate(<<5>>, 257)) == :error
    assert AMF0.decode(<<0x0A, 0xFFFFFFFF::32>>) == :error
  end
end
