defmodule MaveCore.Media.RemoteSourceTest do
  use ExUnit.Case, async: false

  alias MaveCore.Flow.Steps.Support
  alias MaveCore.Media.RemoteSource

  setup {Req.Test, :verify_on_exit!}

  setup do
    old_media_input = Application.get_env(:mave_core, :media_input)
    old_resolver = Application.get_env(:mave_core, :public_http_url_resolver)
    old_req_defaults = Req.default_options()

    Application.put_env(:mave_core, :media_input, max_bytes: 5)

    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{93, 184, 216, 34}]}
    end)

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore_env(:media_input, old_media_input)
      restore_env(:public_http_url_resolver, old_resolver)
      Req.default_options(old_req_defaults)
    end)

    :ok
  end

  test "accepts a response exactly at the configured byte limit" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.text(conn, "12345") end)

    Support.with_temp_dir("remote_source_test", fn tmp_dir ->
      path = Path.join(tmp_dir, "source.bin")

      assert {:ok, %{bytes: 5}} =
               RemoteSource.download_to_file("https://media.example/source", path)

      assert File.read!(path) == "12345"
    end)
  end

  test "halts an oversized response and removes the partial file" do
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.text(conn, "123456") end)

    Support.with_temp_dir("remote_source_test", fn tmp_dir ->
      path = Path.join(tmp_dir, "source.bin")

      assert {:error, {:media_input_too_large, 5}} =
               RemoteSource.download_to_file("https://media.example/source", path)

      refute File.exists?(path)
    end)
  end

  test "rejects private destinations before opening a network connection" do
    Application.put_env(:mave_core, :public_http_url_resolver, fn _host ->
      {:ok, [{127, 0, 0, 1}]}
    end)

    Support.with_temp_dir("remote_source_test", fn tmp_dir ->
      path = Path.join(tmp_dir, "source.bin")

      assert {:error, {:unsafe_source_url, {:blocked_address, {127, 0, 0, 1}}}} =
               RemoteSource.download_to_file("https://media.example/source", path)

      refute File.exists?(path)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)
end
