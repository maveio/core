defmodule MaveCoreWeb.CliAuthLive do
  @moduledoc false

  use MaveCoreWeb, :live_view

  import MaveCoreWeb.DashboardComponents, except: [icon: 1]

  alias MaveCore.CliAuthorizations
  alias MaveCore.Spaces.Space

  def mount(params, _session, socket) do
    user_code = Map.get(params, "user_code", "")
    {state, authorization} = authorization_state(user_code)

    {:ok,
     socket
     |> assign(:page_title, "Authorize Mave CLI")
     |> assign(:state, state)
     |> assign(:authorization, authorization)
     |> assign(:code_form, to_form(%{"user_code" => user_code}, as: :authorization))
     |> assign(:approval_form, approval_form(socket.assigns.current_space))}
  end

  def handle_event("lookup", %{"authorization" => %{"user_code" => user_code}}, socket) do
    normalized = CliAuthorizations.normalize_user_code(user_code)

    if String.length(normalized) == 11 do
      {:noreply, push_navigate(socket, to: ~p"/cli/auth/#{normalized}")}
    else
      form =
        to_form(%{"user_code" => user_code},
          as: :authorization,
          action: :validate,
          errors: [user_code: {"Enter the 10-character code shown in the CLI", []}]
        )

      {:noreply, assign(socket, :code_form, form)}
    end
  end

  def handle_event(
        "authorize",
        %{"authorization" => %{"space_id" => space_id}},
        %{assigns: %{state: :pending}} = socket
      ) do
    with %Space{} = space <- Enum.find(socket.assigns.spaces, &(&1.id == space_id)),
         {:ok, authorization} <-
           CliAuthorizations.approve(socket.assigns.authorization.user_code, space) do
      {:noreply,
       socket
       |> assign(:state, :approved)
       |> assign(:authorization, authorization)}
    else
      nil -> {:noreply, put_flash(socket, :error, "Choose a space you can access.")}
      {:error, :expired_token} -> {:noreply, assign(socket, :state, :expired)}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Could not authorize the CLI.")}
    end
  end

  def handle_event("deny", _params, %{assigns: %{state: :pending}} = socket) do
    case CliAuthorizations.deny(socket.assigns.authorization.user_code) do
      {:ok, authorization} ->
        {:noreply,
         socket
         |> assign(:state, :denied)
         |> assign(:authorization, authorization)}

      {:error, :expired_token} ->
        {:noreply, assign(socket, :state, :expired)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel the authorization.")}
    end
  end

  def handle_event(event, _params, socket) when event in ["authorize", "deny"],
    do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <main
      id="cli-auth-window"
      class="relative isolate flex min-h-svh w-full flex-col items-center bg-stone-100 px-4 py-8 text-stone-700"
      style="font-family: var(--font-sans); color-scheme: light;"
    >
      <section
        aria-labelledby="cli-auth-title"
        class="relative z-10 my-auto flex w-full max-w-sm flex-col items-center rounded-md border border-white border-opacity-50 bg-stone-50 px-8 py-2 shadow-sm shadow-stone-200 ring-1 ring-stone-300 ring-opacity-50"
      >
        <div class="mx-auto mb-4 mt-8 size-24 rounded-full bg-white shadow-stone-200 ring-1 ring-stone-300 ring-opacity-40 transition hover:scale-105 hover:shadow-md">
          <.animated_icon
            name="link"
            class="size-full p-3 opacity-25"
            speed="1"
          />
        </div>
        <div class="mb-6 text-center">
          <p class="text-xs font-medium uppercase tracking-[0.18em] text-blue-400">Mave CLI</p>
          <h1 id="cli-auth-title" class="mt-2 text-lg font-medium text-stone-700">
            {authorization_title(@state)}
          </h1>
        </div>

        <div class="w-full">
          <%= case @state do %>
            <% :enter -> %>
              <p class="mb-6 text-center text-sm leading-5 text-stone-400">
                Enter the code shown in your terminal to continue.
              </p>
              <.form for={@code_form} id="cli-auth-code-form" phx-submit="lookup">
                <label for={@code_form[:user_code].id} class="mb-2 block text-xs text-stone-500">
                  Authorization code
                </label>
                <.dash_input
                  field={@code_form[:user_code]}
                  placeholder="ABCDE-F0123"
                  phx-mounted={JS.focus()}
                  autocomplete="one-time-code"
                />
                <div class="mb-7 mt-6 flex justify-center">
                  <.dash_button id="cli-auth-code-submit" variant="primary">
                    Continue
                  </.dash_button>
                </div>
              </.form>
            <% :pending -> %>
              <div :if={@authorization.client_metadata["device_name"]} class="mb-5 text-center">
                <p id="cli-auth-device-name" class="break-words text-sm font-medium text-stone-600">
                  {@authorization.client_metadata["device_name"]}
                </p>
                <p class="mt-1 text-xs text-stone-400">Device name provided by the CLI</p>
              </div>
              <div class="mb-5 rounded-md bg-white px-4 py-3 text-center shadow-sm shadow-stone-200 ring-1 ring-stone-200/50">
                <div class="text-[0.65rem] uppercase tracking-wider text-stone-400">
                  Authorization code
                </div>
                <div
                  id="cli-auth-user-code"
                  class="mt-1 font-mono text-base tracking-[0.14em] text-stone-600"
                >
                  {@authorization.user_code}
                </div>
              </div>
              <p class="mb-5 text-center text-xs leading-5 text-stone-500">
                Check that this code matches the one in your terminal.
              </p>
              <p class="text-sm leading-6 text-stone-500">
                This grants <strong class="font-medium text-stone-600">Mave CLI</strong>
                read and write access to videos and collections in the selected space.
              </p>
              <.form for={@approval_form} id="cli-auth-approval-form" phx-submit="authorize">
                <div class="mt-6">
                  <label for={@approval_form[:space_id].id} class="mb-2 block text-xs text-stone-500">
                    Space
                  </label>
                  <.dash_select
                    field={@approval_form[:space_id]}
                    options={space_options(@spaces)}
                  />
                </div>
                <p class="mt-4 text-xs leading-5 text-stone-400">
                  You can revoke access in Settings → Developer → API Keys.
                </p>
                <div class="mt-6 flex justify-center">
                  <.dash_button
                    id="cli-auth-authorize"
                    variant="primary"
                    icon="link"
                    loading_on_submit
                    loading_label="Authorizing…"
                  >
                    Authorize Mave CLI
                  </.dash_button>
                </div>
              </.form>
              <div class="mb-5 mt-3 flex justify-center">
                <.dash_button
                  id="cli-auth-deny"
                  type="button"
                  phx-click="deny"
                  variant="ghost"
                >
                  Cancel
                </.dash_button>
              </div>
            <% :approved -> %>
              <.result
                id="cli-auth-approved"
                message="Return to your terminal to continue. You can close this window."
              />
              <.link
                id="cli-auth-settings"
                href={
                  MaveCoreWeb.DashboardRoutes.settings_path(
                    %{id: @authorization.space_id},
                    :developer
                  )
                }
                class="mb-6 mt-4 block text-center text-sm text-blue-400 transition hover:text-blue-500"
              >
                Manage API keys
              </.link>
            <% :denied -> %>
              <.result
                id="cli-auth-denied"
                message="No credentials were created. You can close this window."
              />
            <% :expired -> %>
              <.result
                id="cli-auth-expired"
                message="Return to the CLI and start login again to receive a new code."
              />
            <% :invalid -> %>
              <.result
                id="cli-auth-invalid"
                message="Check the code in your terminal or start login again."
              />
              <.link
                navigate={~p"/cli/auth"}
                class="mb-6 mt-6 block text-center text-xs text-blue-400 transition hover:text-blue-500"
              >
                Enter another code
              </.link>
          <% end %>
        </div>

        <div class="mb-5 mt-1 text-center text-[0.65rem] leading-4 text-stone-400 text-opacity-70">
          Only authorize a CLI login that you started yourself.
        </div>
      </section>

      <div
        aria-hidden="true"
        class="pointer-events-none fixed -bottom-28 mx-auto h-72 w-full max-w-screen-xl pt-0"
      >
        <div class="absolute z-10 hidden size-full bg-opacity-50 xl:flex">
          <div class="h-full w-72 bg-gradient-to-r from-stone-100"></div>
          <div class="flex-grow"></div>
          <div class="h-full w-72 bg-gradient-to-l from-stone-100"></div>
        </div>
        <.animated_icon
          name="waves"
          class="size-full rotate-180 grayscale opacity-10 contrast-200"
          speed="0.5"
          loop
        />
      </div>
    </main>
    """
  end

  attr(:id, :string, required: true)
  attr(:message, :string, required: true)

  defp result(assigns) do
    ~H"""
    <div id={@id} role="status" class="py-4 text-center">
      <p class="text-sm leading-6 text-stone-500">{@message}</p>
    </div>
    """
  end

  defp authorization_title(:approved), do: "Authorization complete"
  defp authorization_title(:denied), do: "Authorization cancelled"
  defp authorization_title(:expired), do: "Code expired"
  defp authorization_title(:invalid), do: "Code not found"
  defp authorization_title(_state), do: "Connect your terminal"

  defp authorization_state(""), do: {:enter, nil}

  defp authorization_state(user_code) do
    case CliAuthorizations.get_for_browser(user_code) do
      {:ok, %{status: status} = authorization} when status in [:pending, :approved, :denied] ->
        {status, authorization}

      {:ok, %{status: :consumed} = authorization} ->
        {:approved, authorization}

      {:error, :expired_token} ->
        {:expired, nil}

      _ ->
        {:invalid, nil}
    end
  end

  defp approval_form(%Space{id: space_id}),
    do: to_form(%{"space_id" => space_id}, as: :authorization)

  defp space_options(spaces) do
    Enum.map(spaces, fn space -> {space_label(space), space.id} end)
  end

  defp space_label(%Space{domains: [domain | _]}), do: domain.domain
  defp space_label(%Space{hash: hash}), do: "Space #{hash}"
end
