defmodule MaveCoreWeb.DashboardComponents.Buttons do
  @moduledoc """
  Button components for the dashboard UI.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  # =============================================================================
  # BUTTON COMPONENTS
  # =============================================================================

  @doc """
  Renders a button matching the ManageUI default button style exactly.

  ## Examples

      <.dash_button label="save" />
      <.dash_button variant="primary" label="create" />
      <.dash_button icon="hero-plus" label="add" />

  ## Variants

  - `default` - ManageUI.button - white bg, stone ring, blue hover
  - `primary` - ManageUI.dark_button - blue bg, white text
  - `ghost` - ManageUI.light_button - transparent, blue text
  - `danger` - red destructive button

  ## Examples

      <.dash_button>save</.dash_button>
      <.dash_button variant="primary">create</.dash_button>
       <.dash_button icon="create">create</.dash_button>
       <.dash_button icon="link" icon_only />
  """
  attr(:variant, :string, values: ~w(default primary ghost danger), default: "default")
  attr(:icon, :string, default: nil)
  attr(:icon_only, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:loading, :boolean, default: false)
  attr(:loading_on_submit, :boolean, default: false)
  attr(:loading_on_click, :boolean, default: false)
  attr(:loading_label, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:type, :string, default: "submit")

  attr(:rest, :global,
    include: ~w(name value form phx-click phx-target phx-value-id phx-value-modal title)
  )

  slot(:inner_block)

  def dash_button(assigns) do
    loading_on_action = assigns.loading_on_submit || assigns.loading_on_click

    loading_state =
      if assigns.loading_on_submit,
        do: "submit",
        else: if(assigns.loading_on_click, do: "click", else: nil)

    assigns =
      assigns
      |> assign(:loading_on_action, loading_on_action)
      |> assign(:loading_state, loading_state)

    ~H"""
    <button
      type={@type}
      class={
        [
          # When icon is present, use flex layout like legacy
          (@icon || @loading || @loading_on_action) && "flex items-center",
          @loading_on_action && "relative overflow-hidden",
          @icon_only && "justify-center",
          button_variant_classes(@variant, @icon != nil),
          (@disabled || @loading) && "opacity-50 pointer-events-none",
          @loading && "cursor-wait",
          @loading_on_submit &&
            "phx-submit-loading:opacity-50 phx-submit-loading:pointer-events-none phx-submit-loading:cursor-wait",
          @loading_on_click &&
            "phx-click-loading:opacity-50 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
          @class
        ]
      }
      disabled={@disabled || @loading}
      {@rest}
    >
      <%= if @loading do %>
        <.button_icon name="loading" centered={@icon_only} />
        <div :if={!@icon_only} class="pr-4 pt-2 pb-2.5">
          {@loading_label || render_slot(@inner_block)}
        </div>
      <% else %>
        <%= if @loading_on_action do %>
          <span class={[
            "inline-flex items-center",
            @loading_state == "submit" && "phx-submit-loading:invisible",
            @loading_state == "click" && "phx-click-loading:invisible"
          ]}>
            <.button_content icon={@icon} icon_only={@icon_only}>
              {render_slot(@inner_block)}
            </.button_content>
          </span>
          <span class={[
            "pointer-events-none absolute inset-0 hidden items-center justify-center overflow-hidden",
            @loading_state == "submit" && "phx-submit-loading:flex",
            @loading_state == "click" && "phx-click-loading:flex"
          ]}>
            <.button_icon name="loading" centered={@icon_only} />
            <div :if={!@icon_only} class="pr-4 pt-2 pb-2.5">
              {@loading_label || render_slot(@inner_block)}
            </div>
          </span>
        <% else %>
          <.button_content icon={@icon} icon_only={@icon_only}>
            {render_slot(@inner_block)}
          </.button_content>
        <% end %>
      <% end %>
    </button>
    """
  end

  attr(:icon, :string, default: nil)
  attr(:icon_only, :boolean, default: false)
  slot(:inner_block)

  defp button_content(assigns) do
    ~H"""
    <%= if @icon do %>
      <.button_icon name={@icon} centered={@icon_only} />
      <div :if={!@icon_only && @inner_block != []} class="pr-4 pt-2 pb-2.5">
        {render_slot(@inner_block)}
      </div>
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

  @doc """
  Dropdown button with menu items - matching ManageUI dropdown pattern.

  ## Examples

      <.dropdown_button id="my-dropdown">
        <:item icon="render" phx-click="render">Render</:item>
        <:item icon="replace" phx-click="replace">Replace</:item>
        <:item icon="delete" danger phx-click="delete">Delete</:item>
      </.dropdown_button>
  """
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:menu_class, :string, default: nil)
  slot(:trigger)

  slot :item do
    attr(:id, :string)
    attr(:icon, :string)
    attr(:danger, :boolean)
    attr(:disabled, :boolean)
    attr(:"phx-click", :any)
    attr(:title, :string)
    attr(:value_id, :string)
  end

  def dropdown_button(assigns) do
    ~H"""
    <div
      class={["relative flex", @class]}
      phx-click-away={JS.add_class("opacity-0 scale-95 pointer-events-none", to: "##{@id}")}
    >
      <%= if @trigger == [] do %>
        <div
          phx-click={JS.toggle_class("opacity-0 scale-95 pointer-events-none", to: "##{@id}")}
          class="flex items-center rounded-md cursor-pointer bg-white hover:ring-blue-500 ring-1 ring-inset ring-stone-200 px-2.5 ml-4 transition ease-out duration-150 hover:scale-110 hover:shadow select-none"
        >
          <div class="text-stone-500 mb-1 text-[1.15rem] px-1">
            ···
          </div>
        </div>
      <% else %>
        {render_slot(@trigger)}
      <% end %>
      <div
        class={[
          "absolute right-0 top-10 bg-white rounded-md shadow transition-['transform,opacity']",
          "overflow-hidden opacity-0 scale-95 pointer-events-none z-50",
          @menu_class
        ]}
        id={@id}
      >
        <.dropdown_item
          :for={item <- @item}
          id={Map.get(item, :id)}
          icon={Map.get(item, :icon)}
          danger={Map.get(item, :danger, false)}
          disabled={Map.get(item, :disabled, false)}
          title={Map.get(item, :title)}
          click={dropdown_item_click(item, @id)}
        >
          {render_slot(item)}
        </.dropdown_item>
      </div>
    </div>
    """
  end

  attr(:id, :string, default: nil)
  attr(:icon, :string, default: nil)
  attr(:danger, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:title, :string, default: nil)
  attr(:click, :any, required: true)
  slot(:inner_block, required: true)

  defp dropdown_item(assigns) do
    ~H"""
    <div
      id={@id}
      phx-click={if @disabled, do: nil, else: @click}
      aria-disabled={@disabled}
      title={@title}
      class={[
        "flex items-center border-b border-stone-100 last:border-none",
        @disabled && "opacity-40 cursor-not-allowed",
        !@disabled && "cursor-pointer hover:bg-stone-100"
      ]}
    >
      <div
        :if={@icon}
        class={[
          "flex shrink-0 items-center justify-center pl-3",
          @danger && "text-red-600",
          !@danger && "text-blue-400"
        ]}
      >
        <.dropdown_icon name={@icon} />
      </div>
      <div class="text-stone-500 select-none font-medium text-sm leading-5 py-2 pl-2 pr-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp dropdown_item_click(item, dropdown_id) do
    close = fn js ->
      JS.add_class(js, "opacity-0 scale-95 pointer-events-none", to: "##{dropdown_id}")
    end

    value =
      case Map.get(item, :value_id) do
        value when is_binary(value) and value != "" -> %{id: value}
        _ -> %{}
      end

    case Map.get(item, :"phx-click") || Map.get(item, "phx-click") do
      %JS{} = js -> close.(js)
      event when is_binary(event) and event != "" -> event |> JS.push(value: value) |> close.()
      _ -> close.(%JS{})
    end
  end

  # Keep menu icons in the same outline family and at the same optical size.
  defp dropdown_icon(assigns) do
    icons = %{
      "render" => "hero-cloud-arrow-down",
      "replace" => "hero-arrow-path",
      "delete" => "hero-trash",
      "archive" => "hero-archive-box",
      "move" => "hero-arrows-right-left",
      "remove" => "hero-arrow-left",
      "create" => "hero-plus",
      "video" => "hero-play-circle",
      "folder" => "hero-folder"
    }

    name =
      if String.starts_with?(assigns.name, "hero-"),
        do: assigns.name,
        else: Map.get(icons, assigns.name, "hero-ellipsis-horizontal-circle")

    assigns = assign(assigns, :name, name)

    ~H"""
    <.icon name={@name} class="block size-4 shrink-0" />
    """
  end

  # Exact classes from ManageUI.button
  # When has_icon is true, omit padding as it's handled by the icon/label wrappers
  defp button_variant_classes("default", true = _has_icon) do
    "ring-inset ring-1 ring-stone-200 rounded-md cursor-pointer bg-white hover:ring-blue-500 active:bg-blue-500 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow text-stone-500 select-none font-medium text-sm"
  end

  defp button_variant_classes("default", _has_icon) do
    "px-3.5 pt-2 pb-2.5 ring-inset ring-1 ring-stone-200 rounded-md cursor-pointer bg-white hover:ring-blue-500 active:bg-blue-500 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow text-stone-500 select-none font-medium text-sm"
  end

  # Exact classes from ManageUI.dark_button
  defp button_variant_classes("primary", true = _has_icon) do
    "bg-blue-500 text-white rounded-md cursor-pointer active:bg-blue-600 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow select-none font-medium text-sm"
  end

  defp button_variant_classes("primary", _has_icon) do
    "px-3.5 pt-2 pb-2.5 bg-blue-500 text-white rounded-md cursor-pointer active:bg-blue-600 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow select-none font-medium text-sm"
  end

  # Exact classes from ManageUI.light_button
  defp button_variant_classes("ghost", _has_icon) do
    "text-blue-400 text-sm px-3 py-1.5 active:bg-blue-500 active:text-white transition duration-100 ease-out hover:scale-110 ring-1 ring-transparent hover:shadow hover:ring-blue-400 cursor-pointer hover:bg-blue-50 rounded-md"
  end

  # Danger/destructive button - red styling
  defp button_variant_classes("danger", true = _has_icon) do
    "ring-inset ring-1 ring-red-200 rounded-md cursor-pointer bg-white hover:ring-red-500 active:bg-red-500 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow text-red-500 select-none font-medium text-sm"
  end

  defp button_variant_classes("danger", _has_icon) do
    "px-3.5 pt-2 pb-2.5 ring-inset ring-1 ring-red-200 rounded-md cursor-pointer bg-white hover:ring-red-500 active:bg-red-500 active:text-white transform-gpu transition ease-out duration-150 hover:scale-110 hover:shadow text-red-500 select-none font-medium text-sm"
  end

  @doc """
  Button with icon - matching ManageUI.button with icon.
  """
  attr(:icon, :string, required: true)
  attr(:label, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(type form phx-click phx-target phx-value-id))

  def icon_button(assigns) do
    ~H"""
    <button
      type="submit"
      class={[
        "flex ml-4 items-center ring-inset ring-1 ring-stone-200 rounded-md cursor-pointer bg-white",
        "hover:ring-blue-500 active:bg-blue-500 active:text-white",
        "transition ease-out duration-150 hover:scale-110 hover:shadow",
        "text-stone-500 select-none font-medium text-sm",
        @disabled && "opacity-50 pointer-events-none",
        @class
      ]}
      disabled={@disabled}
      {@rest}
    >
      <.button_icon name={@icon} />
      <div :if={@label} class="pr-4 pt-2 pb-2.5">{@label}</div>
      <div :if={!@label} class="w-1"></div>
    </button>
    """
  end

  # Icon rendering for buttons - matches ManageUI icon cases
  defp button_icon(%{name: "create"} = assigns) do
    ~H"""
    <div class="pl-2.5 pr-1.5 py-2 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5 border-transparent border"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <line x1="12" y1="5" x2="12" y2="19"></line>
        <line x1="5" y1="12" x2="19" y2="12"></line>
      </svg>
    </div>
    """
  end

  defp button_icon(%{name: "link"} = assigns) do
    assigns = assign_new(assigns, :centered, fn -> false end)

    ~H"""
    <div class={[
      "py-2 text-blue-400",
      @centered && "px-2",
      !@centered && "pl-2.5 pr-1.5"
    ]}>
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5 border-transparent border"
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

  defp button_icon(%{name: "edit"} = assigns) do
    ~H"""
    <div class="flex size-9 items-center justify-center text-stone-500">
      <.icon name="hero-pencil" class="size-[1.125rem]" />
    </div>
    """
  end

  defp button_icon(%{name: "delete"} = assigns) do
    ~H"""
    <div class="p-2.5 text-stone-500">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-4 h-4 transform-gpu"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <polyline points="3 6 5 6 21 6"></polyline>
        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2">
        </path>
        <line x1="10" y1="11" x2="10" y2="17"></line>
        <line x1="14" y1="11" x2="14" y2="17"></line>
      </svg>
    </div>
    """
  end

  defp button_icon(%{name: "close"} = assigns) do
    ~H"""
    <div class="pl-2.5 pr-1.5 py-2 text-red-600">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5 border-transparent border"
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.2"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <line x1="18" y1="6" x2="6" y2="18"></line>
        <line x1="6" y1="6" x2="18" y2="18"></line>
      </svg>
    </div>
    """
  end

  defp button_icon(%{name: "archive"} = assigns) do
    ~H"""
    <div class="pl-3 pr-2.5 py-2 text-blue-400">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="w-5 h-5 border-transparent border"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.2"
        stroke="currentColor"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M20.25 7.5l-.625 10.632a2.25 2.25 0 01-2.247 2.118H6.622a2.25 2.25 0 01-2.247-2.118L3.75 7.5M10 11.25h4M3.375 7.5h17.25c.621 0 1.125-.504 1.125-1.125v-1.5c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v1.5c0 .621.504 1.125 1.125 1.125z"
        />
      </svg>
    </div>
    """
  end

  defp button_icon(%{name: "loading"} = assigns) do
    assigns = assign_new(assigns, :centered, fn -> false end)

    ~H"""
    <div class={[
      "py-2 text-blue-400",
      @centered && "px-2",
      !@centered && "pl-2.5 pr-2.5"
    ]}>
      <span class="w-4 h-4 block rounded-full border-[1.2px] border-current border-r-transparent animate-spin"></span>
    </div>
    """
  end

  # Default/fallback for heroicons (hero-*)
  defp button_icon(%{name: "hero-" <> _rest} = assigns) do
    assigns = assign_new(assigns, :centered, fn -> false end)

    ~H"""
    <div class={[
      "py-2",
      @centered && "px-2 text-stone-500",
      !@centered && "pl-2.5 pr-1.5 text-blue-400"
    ]}>
      <.icon name={@name} class="w-5 h-5" />
    </div>
    """
  end

  # Fallback for unknown icon names - use a generic icon
  defp button_icon(assigns) do
    ~H"""
    <div class="pl-2.5 pr-1.5 py-2 text-blue-400">
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

  @doc """
  Renders a heroicon.
  """
  attr(:name, :string, required: true)
  attr(:class, :any, default: "size-4")

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
