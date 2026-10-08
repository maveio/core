defmodule MaveCoreWeb.UploadSocket do
  use Phoenix.Socket

  alias MaveCore.Accounts
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key
  alias MaveCore.Uploads.Token
  alias MaveCoreWeb.Plugs.Maintenance

  channel "embed:*", MaveCoreWeb.UploadChannel

  @impl true
  def connect(%{"token" => token}, socket, connect_info) do
    with {:ok, claims} <- verify_upload_token(token),
         :ok <- allow_during_maintenance(claims, connect_info) do
      {:ok, assign(socket, :upload_claims, claims)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    :error
  end

  @impl true
  def id(_socket), do: nil

  defp verify_upload_token(token) do
    case Spaces.validate_api_jwt(token) do
      {:ok, %{claims: claims, key: %Key{access_level: :read_write}}} ->
        {:ok, claims}

      _error ->
        {:error, :invalid}
    end
  end

  defp allow_during_maintenance(claims, connect_info) do
    if Maintenance.enabled?() do
      cond do
        Token.admin_maintenance_bypass?(claims) ->
          :ok

        connect_info
        |> current_user_from_connect_info()
        |> Maintenance.internal_user?() ->
          :ok

        true ->
          {:error, :maintenance}
      end
    else
      :ok
    end
  end

  defp current_user_from_connect_info(%{session: session}) when is_map(session) do
    session
    |> user_token_from_session()
    |> user_from_session_token()
  end

  defp current_user_from_connect_info(_connect_info), do: nil

  defp user_token_from_session(session) do
    session["user_token"] || session[:user_token]
  end

  defp user_from_session_token(token) when is_binary(token) do
    Accounts.get_user_by_session_token(token)
  end

  defp user_from_session_token(_token), do: nil
end
