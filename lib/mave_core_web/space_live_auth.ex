defmodule MaveCoreWeb.SpaceLiveAuth do
  @moduledoc false

  alias MaveCore.Accounts
  alias MaveCore.Spaces.Events
  import Phoenix.LiveView

  @doc """
  Checks dashboard access, including an optional deployment-specific grant.

  The `:dashboard_space_access_provider` implements `can_access_space?/3` and
  must revalidate its grant on every call. Context must come from authenticated
  server-side session state, never route or event parameters. Without a provider,
  only current membership grants access. This does not change account/API access.
  """
  def can_access_space?(user, space, context \\ nil) do
    Accounts.can_access_space?(user, space) or provider_access?(user, space, context)
  end

  defp provider_access?(_user, _space, nil), do: false

  defp provider_access?(user, space, context) do
    with module when is_atom(module) and not is_nil(module) <-
           Application.get_env(:mave_core, :dashboard_space_access_provider),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :can_access_space?, 3) do
      module.can_access_space?(user, space, context) == true
    else
      _ -> false
    end
  end

  def attach_component(socket) do
    socket
    |> detach_hook(:current_space_access, :handle_event)
    |> attach_hook(:current_space_access, :handle_event, fn _event, _params, socket ->
      authorize(socket)
    end)
    |> detach_hook(:current_space_access, :handle_async)
    |> attach_hook(:current_space_access, :handle_async, fn _name, _result, socket ->
      authorize(socket)
    end)
  end

  def attach_view(socket) do
    if connected?(socket), do: Events.subscribe_access_changes()

    socket
    |> attach_component()
    |> attach_hook(:current_space_access, :handle_params, fn _params, _url, socket ->
      authorize(socket)
    end)
    |> attach_hook(:current_space_access, :handle_info, fn message, socket ->
      case authorize(socket) do
        {:cont, socket} when message == :space_access_changed -> {:halt, socket}
        result -> result
      end
    end)
  end

  defp authorize(socket) do
    if can_access_space?(
         socket.assigns[:current_user],
         socket.assigns[:current_space],
         socket.assigns[:space_access_context]
       ) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/videos")}
    end
  end
end
