defmodule MaveCore.UsageLimitsTest do
  use ExUnit.Case, async: false

  alias MaveCore.Spaces.Space
  alias MaveCore.UsageLimits

  defmodule AllowAllUsageLimits do
    @behaviour MaveCore.UsageLimits

    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_view_space_data?(_space), do: :ok
    def can_upload_file?(_space, _size), do: :ok
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)
    old_media_input = Application.get_env(:mave_core, :media_input)

    on_exit(fn ->
      case old_backend do
        nil -> Application.delete_env(:mave_core, :usage_limits_backend)
        backend -> Application.put_env(:mave_core, :usage_limits_backend, backend)
      end

      case old_media_input do
        nil -> Application.delete_env(:mave_core, :media_input)
        config -> Application.put_env(:mave_core, :media_input, config)
      end
    end)

    :ok
  end

  test "Core does not impose plan semantics on reserved-looking space hashes" do
    Application.put_env(:mave_core, :usage_limits_backend, AllowAllUsageLimits)

    assert :ok = UsageLimits.can_view_space_data?(%Space{hash: "trial"})
  end

  test "Core rejects unknown and oversized uploads before an allow-all host backend" do
    Application.put_env(:mave_core, :usage_limits_backend, AllowAllUsageLimits)
    Application.put_env(:mave_core, :media_input, max_bytes: 5)
    space = %Space{hash: "demo"}

    assert {:error, :upload_size_required} = UsageLimits.can_upload_file?(space, nil)
    assert :ok = UsageLimits.can_upload_file?(space, 5)

    assert {:error, :upload_file_size_limit_exceeded} =
             UsageLimits.can_upload_file?(space, 6)
  end
end
