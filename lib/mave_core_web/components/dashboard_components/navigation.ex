defmodule MaveCoreWeb.DashboardComponents.Navigation do
  @moduledoc """
  Navigation components for the dashboard UI including menubar, title, subtitle, and footer.
  """

  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  import MaveCoreWeb.DashboardComponents.Buttons
  import MaveCoreWeb.DashboardComponents.AnimatedIcon
  alias MaveCoreWeb.DashboardRoutes
  alias Phoenix.LiveView.JS

  # =============================================================================
  # TITLE COMPONENTS - ManageUI style
  # =============================================================================

  attr :title, :string, required: true
  attr :contenteditable, :boolean, default: false
  attr :field_name, :string, default: "rename[name]"
  attr :change, :string, default: nil
  attr :target, :any, default: nil
  attr :form_id, :string, default: "title-form"
  attr :contenteditable_id, :string, default: "content_editable"
  slot :inner_block

  def title(assigns) do
    ~H"""
    <div class="sticky top-16 mt-16 flex-none z-30">
      <div class="bg-stone-100 border-b border-stone-200/70">
        <div class="relative mx-auto max-w-screen-xl h-16 px-16 flex items-center">
          <%= if @contenteditable do %>
            <div
              class="flex-grow overflow-hidden w-64"
              id={@contenteditable_id}
              phx-hook="content_editable"
            >
              <div
                data-title={@title}
                class="text-stone-600 text-2xl border-b border-transparent font-medium pt-0.5 mr-4 focus:bg-white focus:outline-none focus:ring-1 focus:ring-white rounded-md hover:cursor-text overflow-hidden flex whitespace-nowrap"
                contenteditable="true"
              >
                {@title}
              </div>

              <form id={@form_id} phx-change={@change} phx-target={@target}>
                <input type="hidden" name={@field_name} value={@title} />
              </form>
            </div>
          <% else %>
            <h1 class="flex-grow text-stone-600 text-2xl font-medium">
              {@title}
            </h1>
          <% end %>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # MENUBAR - ManageUI.menubar style
  # =============================================================================

  @doc """
  Tab navigation menubar - matches ManageUI.menubar exactly.

  ## Examples

      <.menubar>
        <.menubar_item icon="general" label="general" path="/settings" active={@live_action == :settings} />
        <.menubar_item icon="team" label="team" path="/settings/team" active={@live_action == :team} />
      </.menubar>
  """
  slot :inner_block, required: true

  def menubar(assigns) do
    ~H"""
    <div class="flex-none z-10">
      <div class="bg-stone-100 border-b border-stone-200/70">
        <div class="mx-auto max-w-screen-xl h-16 px-12 flex items-center">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Individual tab item for menubar.
  """
  attr :icon, :string, required: true
  attr :path, :string, required: true
  attr :active, :boolean, default: false
  attr :hidden, :boolean, default: false
  slot :inner_block, required: true

  def menubar_item(assigns) do
    ~H"""
    <.link
      :if={!@hidden}
      patch={@path}
      class={[
        "relative overflow-hidden mx-4 w-16 h-16 flex flex-col items-center justify-center",
        @active && "cursor-default",
        !@active && "cursor-pointer opacity-60"
      ]}
    >
      <div class="mb-0.5 mt-1.5 text-stone-400/70 h-[1.4rem] w-[1.4rem] flex items-center justify-center">
        <.menubar_icon name={@icon} />
      </div>
      <div class={["text-sm text-stone-400 select-none mb-0.5", @active && "cursor-default"]}>
        {render_slot(@inner_block)}
      </div>
      <div
        :if={@active}
        class="absolute transform-gpu -bottom-[0.1rem] blur-sm w-[0.3rem] h-[0.3rem] bg-blue-600/50"
      />
      <div
        :if={@active}
        class="absolute transform-gpu -bottom-[0.05rem] w-[0.25rem] h-[0.25rem] bg-blue-600/70 rounded-full"
      />
    </.link>
    """
  end

  # Menubar icon helpers - filled SVGs from legacy ManageUI.menubar
  defp menubar_icon(%{name: "general"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path
        fill-rule="evenodd"
        d="M11.49 3.17c-.38-1.56-2.6-1.56-2.98 0a1.532 1.532 0 01-2.286.948c-1.372-.836-2.942.734-2.106 2.106.54.886.061 2.042-.947 2.287-1.561.379-1.561 2.6 0 2.978a1.532 1.532 0 01.947 2.287c-.836 1.372.734 2.942 2.106 2.106a1.532 1.532 0 012.287.947c.379 1.561 2.6 1.561 2.978 0a1.533 1.533 0 012.287-.947c1.372.836 2.942-.734 2.106-2.106a1.533 1.533 0 01.947-2.287c1.561-.379 1.561-2.6 0-2.978a1.532 1.532 0 01-.947-2.287c.836-1.372-.734-2.942-2.106-2.106a1.532 1.532 0 01-2.287-.947zM10 13a3 3 0 100-6 3 3 0 000 6z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  defp menubar_icon(%{name: "team"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path d="M9 6a3 3 0 11-6 0 3 3 0 016 0zM17 6a3 3 0 11-6 0 3 3 0 016 0zM12.93 17c.046-.327.07-.66.07-1a6.97 6.97 0 00-1.5-4.33A5 5 0 0119 16v1h-6.07zM6 11a5 5 0 015 5v1H1v-1a5 5 0 015-5z" />
    </svg>
    """
  end

  defp menubar_icon(%{name: "billing"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path d="M4 4a2 2 0 00-2 2v1h16V6a2 2 0 00-2-2H4z" />
      <path
        fill-rule="evenodd"
        d="M18 9H2v5a2 2 0 002 2h12a2 2 0 002-2V9zM4 13a1 1 0 011-1h1a1 1 0 110 2H5a1 1 0 01-1-1zm5-1a1 1 0 100 2h1a1 1 0 100-2H9z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  defp menubar_icon(%{name: "developer"} = assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path d="M10 3.5a1.5 1.5 0 013 0V4a1 1 0 001 1h3a1 1 0 011 1v3a1 1 0 01-1 1h-.5a1.5 1.5 0 000 3h.5a1 1 0 011 1v3a1 1 0 01-1 1h-3a1 1 0 01-1-1v-.5a1.5 1.5 0 00-3 0v.5a1 1 0 01-1 1H6a1 1 0 01-1-1v-3a1 1 0 00-1-1h-.5a1.5 1.5 0 010-3H4a1 1 0 001-1V6a1 1 0 011-1h3a1 1 0 001-1v-.5z" />
    </svg>
    """
  end

  defp menubar_icon(%{name: "support"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      class="h-5 w-5"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M16.712 4.33a9.027 9.027 0 0 1 1.652 1.306c.51.51.944 1.064 1.306 1.652M16.712 4.33l-3.448 4.138m3.448-4.138a9.014 9.014 0 0 0-9.424 0M19.67 7.288l-4.138 3.448m4.138-3.448a9.014 9.014 0 0 1 0 9.424m-4.138-5.976a3.736 3.736 0 0 0-.88-1.388 3.737 3.737 0 0 0-1.388-.88m2.268 2.268a3.765 3.765 0 0 1 0 2.528m-2.268-4.796a3.765 3.765 0 0 0-2.528 0m4.796 4.796c-.181.506-.475.982-.88 1.388a3.736 3.736 0 0 1-1.388.88m2.268-2.268 4.138 3.448m0 0a9.027 9.027 0 0 1-1.306 1.652c-.51.51-1.064.944-1.652 1.306m0 0-3.448-4.138m3.448 4.138a9.014 9.014 0 0 1-9.424 0m5.976-4.138a3.765 3.765 0 0 1-2.528 0m0 0a3.736 3.736 0 0 1-1.388-.88 3.737 3.737 0 0 1-.88-1.388m2.268 2.268L7.288 19.67m0 0a9.024 9.024 0 0 1-1.652-1.306 9.027 9.027 0 0 1-1.306-1.652m0 0 4.138-3.448M4.33 16.712a9.014 9.014 0 0 1 0-9.424m4.138 5.976a3.765 3.765 0 0 1 0-2.528m0 0c.181-.506.475-.982.88-1.388a3.736 3.736 0 0 1 1.388-.88m-2.268 2.268L4.33 7.288m6.406 1.18L7.288 4.33m0 0a9.024 9.024 0 0 0-1.652 1.306A9.025 9.025 0 0 0 4.33 7.288"
      />
    </svg>
    """
  end

  # Generic fallback for heroicons
  defp menubar_icon(%{name: "hero-" <> _rest} = assigns) do
    ~H"""
    <.icon name={@name} class="h-5 w-5" />
    """
  end

  # Default fallback
  defp menubar_icon(assigns) do
    ~H"""
    <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <circle cx="10" cy="10" r="8" />
    </svg>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, default: nil
  slot :inner_block

  def subtitle(assigns) do
    ~H"""
    <div class="flex-grow flex items-center hover:cursor-default h-8">
      <.subtitle_icon :if={@icon} name={@icon} />
      <div class="flex-grow pb-0.5 text-stone-600 text-xl font-medium">
        {@label}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # Subtitle icon helpers - exact SVGs from legacy ManageUI.subtitle
  defp subtitle_icon(%{name: "general"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <circle cx="12" cy="12" r="3"></circle>
        <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z">
        </path>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "key"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 1 1-7.778 7.778 5.5 5.5 0 0 1 7.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4">
        </path>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "domain"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <circle cx="12" cy="12" r="10"></circle>
        <line x1="2" y1="12" x2="22" y2="12"></line>
        <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z">
        </path>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "link"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
        <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "team"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        width="24"
        height="24"
        stroke-width="1.2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M1 20V19C1 15.134 4.13401 12 8 12V12C11.866 12 15 15.134 15 19V20"
          stroke="currentColor"
          stroke-linecap="round"
        />
        <path
          d="M13 14V14C13 11.2386 15.2386 9 18 9V9C20.7614 9 23 11.2386 23 14V14.5"
          stroke="currentColor"
          stroke-linecap="round"
        />
        <path
          d="M8 12C10.2091 12 12 10.2091 12 8C12 5.79086 10.2091 4 8 4C5.79086 4 4 5.79086 4 8C4 10.2091 5.79086 12 8 12Z"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M18 9C19.6569 9 21 7.65685 21 6C21 4.34315 19.6569 3 18 3C16.3431 3 15 4.34315 15 6C15 7.65685 16.3431 9 18 9Z"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "danger"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.2"
        stroke="currentColor"
        class="w-5 h-5"
      >
        <path
          d="M20.0429 21H3.95705C2.41902 21 1.45658 19.3364 2.22324 18.0031L10.2662 4.01533C11.0352 2.67792 12.9648 2.67791 13.7338 4.01532L21.7768 18.0031C22.5434 19.3364 21.581 21 20.0429 21Z"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linecap="round"
        >
        </path>
        <path d="M12 9V13" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"></path>
        <path
          d="M12 17.01L12.01 16.9989"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
        </path>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "company"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.2"
        stroke="currentColor"
        class="w-5 h-5"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M3.75 21h16.5M4.5 3h15M5.25 3v18m13.5-18v18M9 6.75h1.5m-1.5 3h1.5m-1.5 3h1.5m3-6H15m-1.5 3H15m-1.5 3H15M9 21v-3.375c0-.621.504-1.125 1.125-1.125h3.75c.621 0 1.125.504 1.125 1.125V21"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "cloud"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.2"
        stroke="currentColor"
      >
        <path
          d="M12 4C6 4 6 8 6 10C4.33333 10 1 11 1 15C1 19 4.33333 20 6 20H18C19.6667 20 23 19 23 15C23 11 19.6667 10 18 10C18 8 18 4 12 4Z"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linejoin="round"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "features"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        width="24"
        height="24"
        stroke-width="1.2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M7 13a1 1 0 100-2 1 1 0 000 2z"
          fill="currentColor"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path d="M17 17H7A5 5 0 017 7h10a5 5 0 010 10z" stroke="currentColor" stroke-width="1.2" />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "webhook"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        width="24"
        height="24"
        stroke-width="1.2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M17.5 8C17.5 8 19 9.5 19 12C19 14.5 17.5 16 17.5 16"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M20.5 5C20.5 5 23 7.5 23 12C23 16.5 20.5 19 20.5 19"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M6.5 8C6.5 8 5 9.5 5 12C5 14.5 6.5 16 6.5 16"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M3.5 5C3.5 5 1 7.5 1 12C1 16.5 3.5 19 3.5 19"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M12 13C12.5523 13 13 12.5523 13 12C13 11.4477 12.5523 11 12 11C11.4477 11 11 11.4477 11 12C11 12.5523 11.4477 13 12 13Z"
          fill="currentColor"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "list"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <line x1="8" y1="6" x2="21" y2="6"></line>
        <line x1="8" y1="12" x2="21" y2="12"></line>
        <line x1="8" y1="18" x2="21" y2="18"></line>
        <line x1="3" y1="6" x2="3.01" y2="6"></line>
        <line x1="3" y1="12" x2="3.01" y2="12"></line>
        <line x1="3" y1="18" x2="3.01" y2="18"></line>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "support"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.2"
        stroke="currentColor"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M16.712 4.33a9.027 9.027 0 0 1 1.652 1.306c.51.51.944 1.064 1.306 1.652M16.712 4.33l-3.448 4.138m3.448-4.138a9.014 9.014 0 0 0-9.424 0M19.67 7.288l-4.138 3.448m4.138-3.448a9.014 9.014 0 0 1 0 9.424m-4.138-5.976a3.736 3.736 0 0 0-.88-1.388 3.737 3.737 0 0 0-1.388-.88m2.268 2.268a3.765 3.765 0 0 1 0 2.528m-2.268-4.796a3.765 3.765 0 0 0-2.528 0m4.796 4.796c-.181.506-.475.982-.88 1.388a3.736 3.736 0 0 1-1.388.88m2.268-2.268 4.138 3.448m0 0a9.027 9.027 0 0 1-1.306 1.652c-.51.51-1.064.944-1.652 1.306m0 0-3.448-4.138m3.448 4.138a9.014 9.014 0 0 1-9.424 0m5.976-4.138a3.765 3.765 0 0 1-2.528 0m0 0a3.736 3.736 0 0 1-1.388-.88 3.737 3.737 0 0 1-.88-1.388m2.268 2.268L7.288 19.67m0 0a9.024 9.024 0 0 1-1.652-1.306 9.027 9.027 0 0 1-1.306-1.652m0 0 4.138-3.448M4.33 16.712a9.014 9.014 0 0 1 0-9.424m4.138 5.976a3.765 3.765 0 0 1 0-2.528m0 0c.181-.506.475-.982.88-1.388a3.736 3.736 0 0 1 1.388-.88m-2.268 2.268L4.33 7.288m6.406 1.18L7.288 4.33m0 0a9.024 9.024 0 0 0-1.652 1.306A9.025 9.025 0 0 0 4.33 7.288"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "billing"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        width="24"
        height="24"
        stroke-width="1.2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M2 9V5.6C2 5.26863 2.26863 5 2.6 5H21.4C21.7314 5 22 5.26863 22 5.6V9M2 9V18.4C2 18.7314 2.26863 19 2.6 19H21.4C21.7314 19 22 18.7314 22 18.4V9M2 9H22"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "usage"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        xmlns="http://www.w3.org/2000/svg"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <line x1="18" y1="20" x2="18" y2="10"></line>
        <line x1="12" y1="20" x2="12" y2="4"></line>
        <line x1="6" y1="20" x2="6" y2="14"></line>
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "plans"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        width="24"
        height="24"
        stroke-width="1.2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="M18.5 4.80423C17.4428 4.28906 16.2552 4 15 4C10.5817 4 7 7.58172 7 12C7 16.4183 10.5817 20 15 20C16.2552 20 17.4428 19.7109 18.5 19.1958"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path d="M5 10H16" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" />
        <path d="M5 14H16" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </div>
    """
  end

  defp subtitle_icon(%{name: "invoice"} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        class="w-5 h-5"
        xmlns="http://www.w3.org/2000/svg"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path>
        <polyline points="14 2 14 8 20 8"></polyline>
        <line x1="16" y1="13" x2="8" y2="13"></line>
        <line x1="16" y1="17" x2="8" y2="17"></line>
        <polyline points="10 9 9 9 8 9"></polyline>
      </svg>
    </div>
    """
  end

  # Fallback for hero-* icons
  defp subtitle_icon(%{name: "hero-" <> _rest} = assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <.icon name={@name} class="w-5 h-5" />
    </div>
    """
  end

  # Generic fallback
  defp subtitle_icon(assigns) do
    ~H"""
    <div class="mr-2.5 pb-0.5 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <circle cx="12" cy="12" r="10"></circle>
      </svg>
    </div>
    """
  end

  attr :label, :string, required: true

  def section_title(assigns) do
    ~H"""
    <div class="w-full bg-stone-100 border-b border-stone-200/50">
      <div class="text-xs uppercase text-stone-400 font-medium tracking-wide px-3 py-1.5">
        {@label}
      </div>
    </div>
    """
  end

  # =============================================================================
  # DIVIDER
  # =============================================================================

  @doc """
  Simple horizontal divider for separating sections.

  ## Examples

      <.divider />
      <.divider class="my-8" />
  """
  attr :class, :string, default: nil

  def divider(assigns) do
    ~H"""
    <div class={["w-12 mt-12 mb-4 mx-auto border-t border-stone-100", @class]}></div>
    """
  end

  # =============================================================================
  # FOOTER
  # =============================================================================

  attr :page, :integer, default: nil
  attr :total_pages, :integer, default: nil
  attr :target, :any, default: nil
  attr :static, :boolean, default: false, doc: "Use static positioning (for storybook preview)"
  attr :extra_padding, :boolean, default: false, doc: "Add right padding for settings panel"

  def footer(%{static: true} = assigns) do
    ~H"""
    <div class="bg-stone-100 border-t border-stone-200/70">
      <div class="max-w-screen-xl mx-auto h-16 px-16 flex items-center -mr-0.5">
        <div class="flex-grow"></div>
        <div :if={@page && @total_pages} class="ml-2">
          <.dash_button
            disabled={@page == 1}
            phx-click="previous_page"
            phx-target={@target}
          >
            {gettext("previous")}
          </.dash_button>
        </div>
        <div :if={@page && @total_pages} class="ml-2">
          <.dash_button
            disabled={@page >= @total_pages || @total_pages == 0}
            phx-click="next_page"
            phx-target={@target}
          >
            {gettext("next")}
          </.dash_button>
        </div>
      </div>
    </div>
    """
  end

  def footer(%{page: page} = assigns) when not is_nil(page) do
    ~H"""
    <div class="flex-none h-16"></div>
    <div class={["fixed left-56 bottom-0 w-full z-50 flex", @extra_padding && "pr-56"]}>
      <div class="w-full bg-stone-100 border-t border-stone-200/70">
        <div class="max-w-screen-xl mx-auto h-16 px-16 flex items-center -mr-0.5">
          <div class="flex-grow"></div>
          <div class="ml-2">
            <.dash_button
              disabled={@page == 1}
              phx-click="previous_page"
              phx-target={@target}
            >
              {gettext("previous")}
            </.dash_button>
          </div>
          <div class="ml-2">
            <.dash_button
              disabled={@page >= @total_pages || @total_pages == 0}
              phx-click="next_page"
              phx-target={@target}
            >
              {gettext("next")}
            </.dash_button>
          </div>
        </div>
      </div>
      <div class="flex-none w-56"></div>
    </div>
    """
  end

  def footer(assigns) do
    ~H"""
    <div :if={@static} class="bg-stone-100 border-t border-stone-200/70">
      <div class="h-16"></div>
    </div>
    <div :if={!@static} class="flex-none h-16"></div>
    <div :if={!@static} class={["fixed left-56 bottom-0 w-full z-40 flex", @extra_padding && "pr-56"]}>
      <div class="w-full bg-stone-100 border-t border-stone-200/70">
        <div class="h-16"></div>
      </div>
      <div class="flex-none w-56"></div>
    </div>
    """
  end

  def usermenu(assigns) do
    ~H"""
    <div
      id="usermenu"
      class="duration-75 ease-out transition-all transform-gpu pointer-events-none opacity-0 scale-75 absolute top-12 mt-1 right-3 w-32 bg-white z-20 rounded shadow overflow-hidden"
    >
      <!--
      <div class="text-sm text-stone-500 py-2 px-4 border-b border-stone-200/50 active:bg-blue-500 hover:bg-stone-50 active:text-white cursor-pointer select-none" {patch_to(@route)}>Account</div>
      -->
      <.form for={%{}} action="/logout" method="delete">
        <button
          type="submit"
          class="block w-full text-left text-sm text-stone-500 py-2 px-4 border-b border-stone-200 border-opacity-50 active:bg-blue-500 hover:bg-stone-50 active:text-white cursor-pointer select-none"
        >
          {gettext("log out") |> String.capitalize()}
        </button>
      </.form>
    </div>
    """
  end

  def suggest(assigns) do
    ~H"""
    <div
      id="suggest"
      class="duration-75 ease-out transition-all transform-gpu pointer-events-none opacity-0 scale-75 absolute top-10 mt-1.5 left-0 w-80 bg-white z-20 rounded-b-md shadow overflow-hidden"
    >
      <button
        :for={suggest <- @suggests}
        type="button"
        class="flex w-full items-center gap-3 text-left text-sm text-stone-500 py-2 px-3 border-b border-stone-200/50 active:bg-blue-500 active:text-white cursor-pointer select-none hover:bg-stone-50"
        phx-click="search_embed"
        phx-value-id={suggest.id}
      >
        <div class="h-9 w-16 flex-none overflow-hidden rounded bg-stone-100">
          <img :if={suggest.thumb} src={suggest.thumb} alt="" class="h-full w-full object-cover" />
        </div>
        <div class="min-w-0">
          <div class="truncate text-stone-600">{suggest.name}</div>
          <div class="truncate text-xs text-stone-400 mt-0.5">{suggest.public_id}</div>
        </div>
      </button>
    </div>
    """
  end

  def bar(assigns) do
    ~H"""
    <div class={"absolute w-full top-0 flex-none z-40 #{if @extra_padding, do: "pr-56"}"}>
      <a class="absolute left-6 top-16 w-14 h-16 z-20 transform-gpu" href="#"></a>
      <div class="h-16 flex items-center pr-12 bg-stone-100 border-b border-stone-200/70">
        <div class="relative h-full ml-16">
          <div class="w-64 h-full flex items-center">
            <input
              phx-keyup="search"
              phx-focus="search"
              id="search"
              class="w-full py-2 px-3 bg-white ring-1 ring-stone-200/50 shadow-sm rounded-md hover:opacity-100 hover:shadow-sm placeholder-stone-400 text-stone-500 text-sm outline-none opacity-50 focus:opacity-100 border-y border-transparent"
              placeholder={gettext("search") |> String.capitalize()}
              spellcheck="false"
              phx-click={show_element("#suggest")}
              phx-click-away={hide_element("#suggest")}
            />
          </div>
          <.suggest suggests={@suggests} />
        </div>
        <div class="flex-grow"></div>
        <div
          class="relative flex-none flex h-full items-center cursor-pointer z-20"
          phx-click={show_element("#usermenu")}
          phx-click-away={hide_element("#usermenu")}
        >
          <div class="text-stone-400 text-sm opacity-70 mr-1.5">
            {@user_email}
          </div>
          <div class="pr-3.5 2xl:pr-1">
            <div class="relative w-7 h-7 rounded-full">
              <div class="absolute top-0 left-0 w-5 h-5 m-1 border border-stone-200 rounded-full">
              </div>
              <.animated_icon
                name="avatar"
                class="w-7 h-7 opacity-20 invert"
                speed="1"
              />
            </div>
          </div>
          <.usermenu route={@route} />
        </div>
      </div>
    </div>
    """
  end

  def logo(assigns) do
    ~H"""
    <div class="relative w-full z-10 transform-gpu bg-blue-600">
      <div class="h-32">
        <div class="absolute w-full h-full -top-12">
          <.animated_icon
            name="waves"
            class="w-full h-full opacity-20"
            speed="2"
            loop
          />
        </div>
        <div class="absolute w-full h-full flex items-center px-6">
          <img
            src="/images/glyph.svg"
            class="mt-16 w-14 h-14 p-2 opacity-[0.15] mix-blend-overlay transform-gpu"
          />
        </div>
        <div class="hidden absolute w-full top-0 h-16 border-b border-blue-500"></div>
        <div class="absolute w-full top-0 border-t border-transparent">
          <div class="w-full h-32 border-b border-blue-600"></div>
        </div>
      </div>
    </div>
    """
  end

  def item(%{href: _} = assigns) do
    ~H"""
    <a
      class="flex items-center py-3 px-8 opacity-90 text-white hover:opacity-100 cursor-pointer hover:bg-stone-800 active:bg-blue-600"
      href={@href}
      target="_blank"
    >
      <div class="text-sm">
        {@label}
      </div>
    </a>
    """
  end

  def item(%{icon: _} = assigns) do
    ~H"""
    <.link
      navigate={@route}
      class="flex items-center py-3 px-8 opacity-90 text-white hover:opacity-100 cursor-pointer hover:bg-stone-800 group active:bg-blue-600"
    >
      <div class="w-1 h-1 border-b border-l border-stone-600 group-active:border-white mr-3"></div>
      <div class="text-sm">
        {@label}
      </div>
    </.link>
    """
  end

  def item(assigns) do
    ~H"""
    <.link
      navigate={@route}
      class="flex items-center py-3 px-8 opacity-90 text-white hover:opacity-100 cursor-pointer hover:bg-stone-800 active:bg-blue-600"
    >
      <div class="text-sm">
        {@label}
      </div>
    </.link>
    """
  end

  def menu(assigns) do
    assigns =
      assigns
      |> assign(
        :extra_dashboard_items,
        visible_extra_dashboard_items(assigns, :menu)
      )
      |> assign(:extra_menu_footer_items, visible_extra_dashboard_items(assigns, :menu_footer))

    ~H"""
    <div class="mt-12 z-10 overflow-y-auto mb-48">
      <div class="border-t border-transparent">
        <.item
          label={ngettext("video", "videos", 1) |> String.capitalize()}
          route={DashboardRoutes.videos_path(@current_space)}
        />
        <%!-- <.item label={gettext("showcase") |> String.capitalize()} route="/showcase" /> --%>
        <.item
          label={gettext("data") |> String.capitalize()}
          route={DashboardRoutes.data_path(@current_space)}
        />
        <.item
          :for={item <- @extra_dashboard_items}
          label={item_label(item)}
          {dashboard_item_link_attrs(item, @current_space)}
        />
        <div class="py-5 px-24">
          <div class="w-full border-b border-stone-700/50"></div>
        </div>
        <.item
          label={gettext("settings") |> String.capitalize()}
          route={DashboardRoutes.settings_path(@current_space)}
        />
        <div :if={@extra_menu_footer_items != []} id="dashboard-menu-footer">
          <div class="py-5 px-24">
            <div class="w-full border-b border-stone-700/50"></div>
          </div>
          <.item
            :for={item <- @extra_menu_footer_items}
            label={item_label(item)}
            {dashboard_item_link_attrs(item, @current_space)}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :usage, :map, default: nil

  def sidebar_usage(%{usage: nil} = assigns) do
    ~H"""
    """
  end

  def sidebar_usage(assigns) do
    assigns =
      assign(
        assigns,
        :bandwidth_segments,
        sidebar_usage_segments(assigns.usage.bandwidth_percentage)
      )

    ~H"""
    <div class="border-b border-transparent fixed bottom-16 left-0 z-10 overflow-hidden">
      <div class="w-56 border-t border-stone-800 px-3.5 py-3 bg-stone-900">
        <div class="flex items-center text-xs text-stone-500 text-opacity-70">
          <div class="flex-grow">{ngettext("video", "videos", 1) |> String.capitalize()}</div>
          <div>
            {format_sidebar_count(@usage.embeds_used)} {ngettext(
              "embed",
              "embeds",
              @usage.embeds_used || 0
            )}
          </div>
        </div>
        <div class="w-full h-0.5 rounded-full bg-black/15 my-2.5">
          <div
            class="relative h-full rounded-full bg-blue-600 transition-all ease-out duration-125"
            style={"width: #{sidebar_percent(@usage.embeds_percentage)}%;"}
          >
          </div>
        </div>
      </div>
      <div class="w-56 border-t border-stone-800 px-3.5 py-3 bg-stone-900">
        <div class="flex items-center text-xs text-stone-500 text-opacity-70">
          <div class="flex-grow">{gettext("Bandwidth") |> String.capitalize()}</div>
          <div>{format_sidebar_bandwidth(@usage.bandwidth_used_gb)}</div>
        </div>
        <div class="flex w-full h-0.5 overflow-hidden rounded-full bg-black/15 my-2.5">
          <div
            data-usage-segment="within-limit"
            class="h-full bg-blue-600 transition-all ease-out duration-125"
            style={"width: #{@bandwidth_segments.within_limit}%;"}
          >
          </div>
          <div
            :if={@bandwidth_segments.overage > 0}
            data-usage-segment="overage"
            class="h-full bg-red-500 transition-all ease-out duration-125"
            style={"width: #{@bandwidth_segments.overage}%;"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  def notification(assigns) do
    ~H"""
    <div class="absolute w-56 z-40 p-3">
      <div class={"relative w-full h-full bg-black/20 rounded-lg shadow-sm text-stone-600 text-sm flex flex-col justify-center #{if @latest_update.link, do: "transition transform-gpu duration-150 hover:scale-102 cursor-pointer hover:bg-blue-400/20 hover:shadow-lg active:bg-blue-200/20"}"}>
        <div
          class="relative pl-2 mr-4 py-1.5 text-xs text-white/80"
          onclick={if @latest_update.link, do: "window.open('#{@latest_update.link}', '_blank');"}
        >
          {@latest_update.message}
        </div>
        <div class="absolute w-5 right-0 h-full flex justify-end">
          <div
            class="w-5 h-5 text-white flex items-center justify-center cursor-pointer opacity-90 hover:opacity-100 hover:scale-125 transition z-50"
            phx-click="dismiss_latest_update"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="w-3 h-3"
              width="24"
              height="24"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <line x1="18" y1="6" x2="6" y2="18"></line>
              <line x1="6" y1="6" x2="18" y2="18"></line>
            </svg>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def spacepicker(assigns) do
    assigns =
      assigns
      |> assign(:selected_space, selected_space(assigns.spaces, assigns.current_space))
      |> assign(:extra_spacepicker_items, visible_extra_dashboard_items(assigns, :spacepicker))

    ~H"""
    <div class="fixed w-56 z-60 h-16 border-b border-transparent bottom-0 left-0">
      <div
        id="spacepicker"
        class="duration-75 ease-out transition-all transform-gpu opacity-0 scale-75 pointer-events-none absolute w-full bottom-8 mb-2 p-3 z-50"
      >
        <div class="max-h-[30vh] w-full overflow-x-hidden overflow-y-auto ring-inset ring-1 ring-stone-700/50 rounded-md bg-stone-800 shadow-md">
          <div
            :if={@allow_creation}
            class="flex items-center hover:ring-blue-500 active:bg-blue-500 text-stone-500 active:text-white border-b border-stone-900/70 cursor-pointer ring-inset ring-transparent ring-1 hover:ring-blue-500 rounded-t-md"
          >
            <div class="ml-1.5">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.2"
                stroke="currentColor"
                class="opacity-70 w-5 h-5 m-0.5"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
              </svg>
            </div>
            <div
              id="spacepicker-create-space"
              class="grow py-1.5 px-1 select-none text-sm border-b border-transparent"
              phx-click="create_space"
              phx-click-away={hide_element("#spacepicker")}
            >
              {gettext("add")}
            </div>
          </div>
          <.space_item
            :for={{space, index} <- Enum.with_index(@spaces)}
            space={space}
            index={index}
            current_space={@current_space}
            allow_creation={@allow_creation}
            total={length(@spaces)}
          />
        </div>
      </div>
      <div class="absolute bottom-0 left-0 w-56 h-16 p-3 flex items-center border-t bg-stone-900 border-stone-800">
        <div class="w-full flex items-stretch ring-inset ring-1 ring-transparent/50 rounded-md bg-black/20 overflow-hidden transform-gpu transition ease-out duration-150 hover:ring-blue-500">
          <div
            class="min-w-0 grow flex items-center cursor-pointer text-stone-500 active:text-white transition ease-out duration-150 hover:bg-white/2 active:bg-blue-500"
            phx-click={show_element("#spacepicker")}
            phx-click-away={hide_element("#spacepicker")}
          >
            <div class="ml-2 shrink-0 text-stone-700">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="1"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"
                />
              </svg>
            </div>
            <div
              class="min-w-0 grow truncate py-1.5 px-1 select-none text-sm border-b border-transparent"
              title={space_domain_label(@selected_space)}
            >
              {space_domain_label(@selected_space)}
            </div>
            <div class="mr-2 text-blue-500 hidden">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="w-5 h-5"
                width="24"
                height="24"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <circle cx="12" cy="12" r="10"></circle>
                <line x1="12" y1="16" x2="12" y2="12"></line>
                <line x1="12" y1="8" x2="12.01" y2="8"></line>
              </svg>
            </div>
          </div>
          <.spacepicker_item :for={item <- @extra_spacepicker_items} item={item} />
        </div>
      </div>
    </div>
    """
  end

  defp spacepicker_item(assigns) do
    ~H"""
    <.link
      patch={@item.path}
      class={[
        "shrink-0 w-10 h-10 flex items-center justify-center",
        "relative text-stone-600 transform-gpu transition ease-out duration-150",
        "hover:bg-white/2 hover:text-white active:bg-blue-500"
      ]}
      title={item_label(@item)}
    >
      <div class="absolute inset-y-2 left-0 w-px bg-stone-700/50 pointer-events-none"></div>
      <svg
        :if={Map.get(@item, :id) == :spaces}
        xmlns="http://www.w3.org/2000/svg"
        class="w-4.5 h-4.5"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.25"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M6 7.5h12" />
        <path d="M6 12h8" />
        <path d="M6 16.5h12" />
        <path d="M4 7.5h.01" />
        <path d="M4 12h.01" />
        <path d="M4 16.5h.01" />
      </svg>
    </.link>
    """
  end

  defp space_item(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center hover:ring-blue-500 active:bg-blue-500 text-stone-500 active:text-white",
        "border-b border-stone-900/70 cursor-pointer ring-inset ring-transparent ring-1 hover:ring-blue-500",
        @index == 0 && !@allow_creation && "rounded-t-md",
        @index == @total - 1 && "rounded-b-md border-b-none"
      ]}
      phx-click="switch_space"
      phx-value-id={@space.id}
    >
      <div class="ml-1.5 shrink-0">
        <.animated_icon
          name="globe"
          class={[
            "w-6 h-6 transition-opacity duration-150",
            if(@current_space.id == @space.id, do: "opacity-100", else: "opacity-20")
          ]}
          speed="1"
        />
      </div>
      <div
        class="min-w-0 grow truncate py-1.5 px-1 select-none text-sm border-b border-transparent"
        title={space_domain_label(@space)}
      >
        {space_domain_label(@space)}
      </div>
    </div>
    """
  end

  defp space_domain_label(space) do
    case first_space_domain(space) do
      domain when is_binary(domain) and domain != "" ->
        domain

      _ ->
        gettext("no domain set") |> String.capitalize()
    end
  end

  defp first_space_domain(space) when is_map(space) do
    case Map.get(space, :domains) do
      domains when is_list(domains) ->
        domains
        |> List.first()
        |> extract_domain()

      _ ->
        nil
    end
  end

  defp first_space_domain(_), do: nil

  defp selected_space(spaces, %{id: current_space_id} = current_space) when is_list(spaces) do
    Enum.find(spaces, current_space, &(&1.id == current_space_id))
  end

  defp selected_space(_spaces, current_space), do: current_space

  defp format_sidebar_count(nil), do: "0"
  defp format_sidebar_count(count) when count >= 1_000_000, do: "#{div(count, 1_000_000)}M"

  defp format_sidebar_count(count) when count >= 1_000 do
    "#{div(count, 1_000)},#{rem(count, 1_000) |> Integer.to_string() |> String.pad_leading(3, "0")}"
  end

  defp format_sidebar_count(count), do: Integer.to_string(max(count, 0))

  defp format_sidebar_bandwidth(nil), do: "0 GB"

  defp format_sidebar_bandwidth(gigabytes) when gigabytes >= 1000 do
    "#{format_sidebar_count(round(gigabytes / 1000))} TB"
  end

  defp format_sidebar_bandwidth(gigabytes), do: "#{format_sidebar_count(round(gigabytes))} GB"

  defp sidebar_percent(nil), do: 0
  defp sidebar_percent(percent) when percent < 0, do: 0
  defp sidebar_percent(percent) when percent > 100, do: 100
  defp sidebar_percent(percent), do: percent

  defp sidebar_usage_segments(percent) when is_number(percent) and percent > 100 do
    within_limit = Float.round(10_000.0 / percent, 4)
    %{within_limit: within_limit, overage: Float.round(100.0 - within_limit, 4)}
  end

  defp sidebar_usage_segments(percent) do
    %{within_limit: sidebar_percent(percent), overage: 0}
  end

  defp visible_extra_dashboard_items(assigns, placement) do
    Application.get_env(:mave_core, :extra_dashboard_items, [])
    |> Enum.filter(fn item ->
      Map.get(item, :placement, :menu) == placement and dashboard_item_visible?(item, assigns)
    end)
  end

  defp dashboard_item_link_attrs(%{href: href}, _current_space), do: [href: href]

  defp dashboard_item_link_attrs(%{path: {module, function, args}}, current_space) do
    [route: apply(module, function, [current_space | args])]
  end

  defp dashboard_item_link_attrs(%{path: path}, _current_space), do: [route: path]

  defp dashboard_item_visible?(item, %{
         current_user: %{id: _} = current_user,
         current_space: %{id: _} = current_space
       }) do
    case Map.get(item, :visible?) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [current_user, current_space])

      nil ->
        true

      value ->
        value in [true, false] and value
    end
  end

  defp dashboard_item_visible?(item, _assigns) do
    Map.get(item, :visible?, false) in [nil, true]
  end

  defp item_label(item) do
    Map.fetch!(item, :label)
  end

  defp extract_domain(%{domain: domain}) when is_binary(domain), do: domain
  defp extract_domain(%{"domain" => domain}) when is_binary(domain), do: domain
  defp extract_domain(_), do: nil

  defp show_element(js \\ %JS{}, element) do
    js
    |> JS.remove_class("pointer-events-none opacity-0 scale-75", to: element)
    |> JS.add_class("opacity-100 scale-100", to: element)
  end

  defp hide_element(js \\ %JS{}, element) do
    js
    |> JS.remove_class("opacity-100 scale-100", to: element)
    |> JS.add_class("opacity-0 scale-75 pointer-events-none", to: element)
  end
end
