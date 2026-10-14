defmodule MaveCore.TestSupport.AnalyticsUsageLimitStub do
  @moduledoc false
  @behaviour MaveCore.UsageLimits

  def can_create_video_embed?(_space), do: :ok
  def can_add_space_member?(_space, _role), do: :ok
  def can_view_space_data?(_space), do: {:error, :data_unavailable}
end
