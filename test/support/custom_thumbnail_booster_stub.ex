defmodule MaveCore.TestSupport.CustomThumbnailBoosterStub do
  @moduledoc false

  alias MaveCore.TestSupport.FlowStorageAdapterStub

  def encode_to_storage(input_url, upload, options) do
    send(Application.fetch_env!(:mave_core, :thumbnail_booster_test_pid), {
      :thumbnail_booster_request,
      input_url,
      options
    })

    case Application.get_env(:mave_core, :thumbnail_booster_test_error) do
      nil ->
        {:ok, _} =
          FlowStorageAdapterStub.put_public(
            upload["test_bucket"],
            upload["test_path"],
            "converted-#{options[:frame_codec]}",
            upload["test_content_type"],
            upload["test_region"]
          )

        {:ok, %{elapsed_ms: 5}}

      reason ->
        {:error, reason}
    end
  end
end
