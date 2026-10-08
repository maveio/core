defmodule MaveCoreWeb.DashboardComponents.Info do
  @moduledoc """
  Info box and tooltip components for the dashboard UI.
  """

  use Phoenix.Component

  # =============================================================================
  # INFO BOX COMPONENT
  # =============================================================================

  @doc """
  Info box - exact ManageUI styling with inline icon.

  Styling: stone-50 bg, stone-400 text, ring border, blue-300 icon inline.
  """
  slot :inner_block, required: true

  def info_box(assigns) do
    ~H"""
    <div class="px-3 py-2.5 rounded-md bg-stone-50 text-stone-400 shadow-sm text-sm ring-1 ring-inset ring-stone-200/70">
      <div class="inline-block mr-0.5 -mb-0.5 text-blue-300">
        <svg
          width="24"
          height="24"
          class="w-3.5 h-3.5"
          stroke-width="2"
          viewBox="0 0 24 24"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
        >
          <path
            d="M12 11.5V16.5"
            stroke="currentColor"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
          <path
            d="M12 7.51L12.01 7.49889"
            stroke="currentColor"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
          <path
            d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z"
            stroke="currentColor"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Info hover icon - displays an info icon that shows a tooltip on hover.

  Matches the pattern used in legacy ManageUI for feature rows (e.g., "Public sharing").

  ## Examples

      <.info_hover>
        You can use a CNAME record to share files through your own domain.
      </.info_hover>

      <.info_hover color="red">
        This action cannot be undone.
      </.info_hover>
  """
  attr :color, :string, default: "blue"
  attr :position, :string, default: "right"
  attr :tooltip_class, :string, default: nil
  slot :inner_block, required: true

  def info_hover(assigns) do
    icon_color = if assigns.color == "red", do: "text-red-400", else: "text-blue-300"
    position_class = if assigns.position == "left", do: "right-0", else: ""
    assigns = assign(assigns, icon_color: icon_color, position_class: position_class)

    ~H"""
    <div class={"relative ml-2 #{@icon_color} cursor-pointer group flex items-center"}>
      <svg
        width="24"
        height="24"
        class="w-3.5 h-3.5"
        stroke-width="2"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path d="M12 11.5V16.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" />
        <path
          d="M12 7.51L12.01 7.49889"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <path
          d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
      <div class={[
        "absolute top-7 transition-all duration-150 ease-out scale-75 opacity-0 pointer-events-none group-hover:pointer-events-auto group-hover:opacity-100 group-active:opacity-100 group-hover:scale-100 group-active:scale-100 px-3 py-2.5 rounded-md bg-stone-50 text-stone-400 shadow-sm text-sm mb-8 ring-1 ring-inset ring-stone-200/70 z-10",
        "w-72",
        @position_class,
        @tooltip_class
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
