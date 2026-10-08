defmodule MaveCoreWeb.DashboardComponents.Settings do
  @moduledoc """
  Settings panel components for the dark-themed video/embed settings sidebar.

  These components are designed for the settings panel that appears on the right
  side when editing video/embed configurations. They use a dark theme (stone-900)
  unlike the main dashboard components which use a light theme.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  # =============================================================================
  # SETTINGS PANEL CONTAINER
  # =============================================================================

  @doc """
  Container for the dark-themed settings sidebar panel.

  ## Examples

      <.settings_panel id="video_settings">
        <.settings_header title="dimensions" />
        <!-- content -->
      </.settings_panel>
  """
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :footer

  def settings_panel(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "absolute bg-stone-900 w-56 h-full min-h-screen select-none",
        "border-l border-stone-800 flex flex-col",
        @class
      ]}
      {@rest}
    >
      <div class="flex-none h-8 flex items-center px-3">
        <img src="/images/glyph.svg" class="w-4 h-4 opacity-30 invert" alt="" />
      </div>

      <div class="flex-grow overflow-y-scroll scrollbar-none [scrollbar-width:none] [-ms-overflow-style:none] [&::-webkit-scrollbar]:hidden">
        {render_slot(@inner_block)}
      </div>

      <div :if={@footer != []} class="flex-none">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end

  # =============================================================================
  # SETTINGS HEADER
  # =============================================================================

  @doc """
  Section header row with optional toggle or add button.

  Used to create section dividers within the settings panel with uppercase
  titles and optional interactive elements.

  ## Examples

      <.settings_header title="dimensions" />
      <.settings_header title="aspect ratio" toggable toggle_enabled={@aspect_ratio_enabled} />
      <.settings_header title="subtitles" addable phx-click="add" phx-target={@myself} />
  """
  attr :title, :string, required: true
  attr :toggable, :boolean, default: false
  attr :toggle_enabled, :boolean, default: false
  attr :addable, :boolean, default: false
  attr :disclosable, :boolean, default: false
  attr :expanded, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :value, :any, default: nil
  attr :rest, :global, include: ~w(phx-click phx-target phx-value-title phx-value-id)

  def settings_header(assigns) do
    ~H"""
    <div
      class={[
        "w-full h-8 px-2.5 border-y border-stone-800 font-semibold flex items-center text-xs uppercase text-stone-500",
        @disclosable && !@disabled && "cursor-pointer",
        !@disclosable && "cursor-default",
        @disabled && "opacity-50"
      ]}
      {@rest}
    >
      <div class="flex-grow pb-0.5">{@title}</div>

      <div :if={@disclosable} class="mr-1 flex h-4 w-4 items-center justify-center text-stone-600">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          class={[
            "h-4 w-4 transition-transform duration-150",
            @expanded && "rotate-180"
          ]}
        >
          <path
            fill-rule="evenodd"
            d="M5.23 7.21a.75.75 0 0 1 1.06.02L10 11.168l3.71-3.938a.75.75 0 1 1 1.08 1.04l-4.25 4.51a.75.75 0 0 1-1.08 0l-4.25-4.51a.75.75 0 0 1 .02-1.06Z"
            clip-rule="evenodd"
          />
        </svg>
      </div>

      <div
        :if={@addable}
        class="h-[1.125rem] w-[1.125rem] bg-stone-800 border-stone-900 mx-[0.1875rem] rounded-full flex items-center justify-center cursor-pointer hover:bg-stone-700"
        {@rest}
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
          stroke-width="2"
          stroke="currentColor"
          class="w-4 h-4 border-transparent border-b-[0.5px]"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
        </svg>
      </div>

      <div
        :if={@toggable}
        class={[
          "h-6 flex items-center",
          @disabled && "opacity-50",
          !@disabled && "cursor-pointer"
        ]}
        {@rest}
      >
        <.settings_toggle enabled={@toggle_enabled} disabled={@disabled} />
      </div>
    </div>
    """
  end

  # =============================================================================
  # SETTINGS TOGGLE
  # =============================================================================

  @doc """
  Small dark-theme toggle switch for settings panel.

  This is a smaller toggle (w-6 h-3) designed for the dark settings panel,
  different from the larger dashboard toggle (w-10) in data_table.ex.

  ## Examples

      <.settings_toggle enabled={true} />
      <.settings_toggle enabled={false} phx-click="toggle" phx-target={@myself} />
  """
  attr :enabled, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-target phx-value-title phx-value-id)

  def settings_toggle(assigns) do
    ~H"""
    <div
      class={[
        "w-6 h-3 rounded-full transition-all ease-out duration-75",
        @enabled && "bg-blue-600",
        !@enabled && "bg-stone-700/40",
        @disabled && "pointer-events-none opacity-60"
      ]}
      {@rest}
    >
      <div
        class={[
          "w-2.5 h-2.5 ring-1 rounded-full shadow transition-all ease-out duration-75",
          @enabled && "ml-3.5 shadow-blue-900 ring-white bg-white",
          !@enabled && "shadow-stone-900 ring-stone-600 bg-stone-600"
        ]}
        style="margin-top: 0.05rem;"
      >
      </div>
    </div>
    """
  end

  # =============================================================================
  # SETTINGS OPTION GRID
  # =============================================================================

  @doc """
  Container grid for option cards with animations.

  Shows/hides content with scale and opacity transitions, typically used
  in conjunction with a toggable settings_header.

  ## Examples

      <.settings_option_grid visible={@controls_enabled}>
        <.settings_option label="full" value={:full} selected={@controls == :full} />
        <.settings_option label="big" value={:big} selected={@controls == :big} />
      </.settings_option_grid>
  """
  attr :visible, :boolean, default: true
  attr :cols, :integer, default: 2
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def settings_option_grid(assigns) do
    grid_class = "grid-cols-#{assigns.cols}"
    assigns = assign(assigns, :grid_class, grid_class)

    ~H"""
    <div class={[
      "grid gap-3 text-sm text-stone-400 select-none transform-gpu transition-transform ease-out",
      @grid_class,
      @visible && "p-3 scale-100 opacity-100",
      !@visible && "scale-90 h-0 overflow-hidden opacity-0",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # =============================================================================
  # SETTINGS OPTION
  # =============================================================================

  @doc """
  Selectable option card for settings (aspect ratio, poster type, controls, etc.).

  Displays as a clickable card with an icon slot and label. Shows a blue ring
  when selected or on hover.

  ## Examples

      <.settings_option label="16:9" value={:r16_9} selected={@aspect_ratio == :r16_9}>
        <div class="h-4 aspect-video border border-stone-500 mt-1.5 rounded-sm"></div>
      </.settings_option>
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-target phx-value-title phx-value-label)

  slot :inner_block

  def settings_option(assigns) do
    ~H"""
    <div
      class={[
        "bg-stone-800 h-16 rounded-sm flex flex-col items-center justify-center text-stone-400",
        "ring-1 ring-inset hover:ring-blue-600",
        @selected && "ring-blue-600",
        !@selected && "ring-transparent",
        @disabled && "opacity-50 pointer-events-none",
        !@disabled && "cursor-pointer"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <div class="mt-1.5">{@label}</div>
    </div>
    """
  end

  # =============================================================================
  # COLOR PICKER
  # =============================================================================

  @doc """
  Color picker with preset swatches and hex input.

  Shows a color preview button that opens a dropdown with color swatches.
  Toggle/dismiss is handled entirely client-side via `Phoenix.LiveView.JS`.

  ## Examples

      <.color_picker
        id="video-color"
        color={@color}
        opacity={@opacity}
        on_select={JS.push("change_color", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :color, :string, default: nil
  attr :opacity, :integer, default: 100
  attr :on_select, :any, required: true
  attr :rest, :global

  @colors [
    {"ef4444", "red-500"},
    {"eab308", "yellow-500"},
    {"2563eb", "blue-600"},
    {"16a34a", "green-600"},
    {"7e22ce", "purple-700"},
    {"65a30d", "lime-600"},
    {"f59e0b", "amber-500"},
    {"db2777", "pink-600"},
    {"0d9488", "teal-600"},
    {"f43f5e", "rose-500"},
    {"0ea5e9", "sky-500"},
    {"c026d3", "fuchsia-600"},
    {"1c1917", "stone-900"},
    {"transparent", nil}
  ]

  def color_picker(assigns) do
    assigns = assign(assigns, :colors, @colors)

    ~H"""
    <div class="relative group cursor-pointer">
      <div
        phx-click={
          JS.toggle(
            to: "##{@id}-dropdown",
            in: {"duration-100", "opacity-0 scale-90", "opacity-100 scale-100"},
            out: {"duration-100", "opacity-100 scale-100", "opacity-0 scale-90"}
          )
        }
        class="flex items-center h-full rounded overflow-hidden"
      >
        <div
          class="w-9 h-6 relative"
          style={"background: #{if @color, do: "##{@color}", else: "transparent"}"}
        >
          <div class="absolute w-full h-full rounded-l ring-1 ring-inset ring-stone-700/50"></div>
          <div :if={is_nil(@color)} class="grid grid-cols-3 bg-stone-900">
            <div class="w-3 h-3 bg-stone-800"></div>
            <div class="w-3 h-3"></div>
            <div class="w-3 h-3 bg-stone-800"></div>
            <div class="w-3 h-3"></div>
            <div class="w-3 h-3 bg-stone-800"></div>
            <div class="w-3 h-3"></div>
          </div>
        </div>
        <div class="w-3 h-6 bg-stone-800 flex items-center justify-center text-stone-500">
          <svg
            class="w-3"
            width="24"
            height="24"
            stroke-width="2.5"
            viewBox="0 0 24 24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <path
              d="M6 9L12 15L18 9"
              stroke="currentColor"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </div>
      </div>

      <div
        id={"#{@id}-dropdown"}
        class="absolute z-10 top-8 -left-1.5 w-56 pr-3.5 hidden"
        phx-click-away={
          JS.hide(
            to: "##{@id}-dropdown",
            transition: {"duration-100", "opacity-100 scale-100", "opacity-0 scale-90"}
          )
        }
      >
        <div class={[
          "w-full h-full p-1 bg-stone-900 rounded shadow border border-stone-800 ring-1 ring-inset ring-stone-700/50",
          "grid grid-cols-8"
        ]}>
          <div :for={{hex, _class} <- @colors} class="p-1">
            <div
              phx-click={
                @on_select
                |> JS.hide(
                  to: "##{@id}-dropdown",
                  transition: {"duration-100", "opacity-100 scale-100", "opacity-0 scale-90"}
                )
              }
              phx-value-color={hex}
              class={[
                "w-4 h-4 rounded-full cursor-pointer ring-1 ring-inset ring-stone-700/50",
                hex == "transparent" && "relative overflow-hidden"
              ]}
              style={if hex != "transparent", do: "background: ##{hex}"}
            >
              <div :if={hex == "transparent"} class="absolute w-full h-full rounded-full"></div>
              <div :if={hex == "transparent"} class="grid grid-cols-2 bg-stone-900">
                <div class="w-2 h-2 bg-stone-800"></div>
                <div class="w-2 h-2"></div>
                <div class="w-2 h-2"></div>
                <div class="w-2 h-2 bg-stone-800"></div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
