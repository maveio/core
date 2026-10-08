defmodule MaveCore.PublicHttpUrlTest do
  use ExUnit.Case, async: false

  alias MaveCore.PublicHttpUrl

  setup do
    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)

    on_exit(fn ->
      restore_env(:public_http_url_resolver, old_resolver)
    end)

    :ok
  end

  test "rejects loopback and link-local address literals" do
    assert {:error, {:blocked_address, {127, 0, 0, 1}}} =
             PublicHttpUrl.validate("http://127.0.0.1:4000/")

    assert {:error, {:blocked_address, {169, 254, 42, 42}}} =
             PublicHttpUrl.validate("http://169.254.42.42/conf")
  end

  test "rejects non-canonical loopback address literals" do
    for url <- [
          "http://127.1/",
          "http://2130706433/",
          "http://0x7f000001/",
          "http://0177.0.0.1/"
        ] do
      assert {:error, {:blocked_address, {127, 0, 0, 1}}} = PublicHttpUrl.validate(url)
    end
  end

  test "rejects hosts when any resolved address is not public" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}, {10, 0, 0, 12}]}
    end)

    assert {:error, {:blocked_address, {10, 0, 0, 12}}} =
             PublicHttpUrl.validate("https://example.com/video.mp4")
  end

  test "pins request URL to the validated address and preserves hostname for Host and SNI" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, opts} =
             PublicHttpUrl.req_options("https://example.com:8443/video.mp4?token=abc",
               connect_options: [timeout: 5_000]
             )

    assert opts[:url] == "https://93.184.216.34:8443/video.mp4?token=abc"
    assert opts[:redirect] == false
    assert opts[:connect_options][:hostname] == "example.com"
    assert opts[:connect_options][:timeout] == 5_000
  end

  test "passes embedded credentials as basic auth without keeping them in the pinned URL" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, opts} =
             PublicHttpUrl.req_options("https://user:pa%24%24@example.com/video.mp4")

    assert opts[:url] == "https://93.184.216.34/video.mp4"
    assert opts[:auth] == {:basic, "user:pa$$"}
  end

  test "keeps explicit authorization headers ahead of embedded credentials" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn "example.com" ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    assert {:ok, opts} =
             PublicHttpUrl.req_options("https://user:pass@example.com/video.mp4",
               headers: [{"authorization", "Bearer token"}]
             )

    refute Keyword.has_key?(opts, :auth)
    assert opts[:headers] == [{"authorization", "Bearer token"}]
  end

  test "rejects non-http schemes" do
    assert {:error, :invalid_http_url} = PublicHttpUrl.validate("file:///etc/passwd")
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
