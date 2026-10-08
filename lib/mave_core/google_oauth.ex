defmodule MaveCore.GoogleOAuth do
  @moduledoc """
  Runtime gate for the optional Google OAuth integration.

  Hosts must opt in explicitly and provide both OAuth credentials before Core
  exposes Google login or account-linking controls.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:mave_core, :google_oauth_enabled, false) == true and configured?()
  end

  @spec configured?() :: boolean()
  def configured? do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])

    present?(Keyword.get(config, :client_id)) and
      present?(Keyword.get(config, :client_secret))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
