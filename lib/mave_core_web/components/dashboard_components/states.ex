defmodule MaveCoreWeb.DashboardComponents.States do
  @moduledoc """
  Empty state and breadcrumb components for the dashboard UI.
  """

  use Phoenix.Component

  import MaveCoreWeb.DashboardComponents.AnimatedIcon

  # =============================================================================
  # EMPTY STATE
  # =============================================================================

  @doc """
  Centered empty state with icon, title, optional description and CTA.

  ## Examples

      <.empty_state title="Create your first video" icon="upload">
        Upload a video to get started.
        <:action>
          <.dash_button icon="create">create</.dash_button>
        </:action>
      </.empty_state>

      <.empty_state title="Your archive is empty" icon="folder" />
  """
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  slot :inner_block
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-16">
      <div :if={@icon} class="w-24 h-24 flex items-center justify-center">
        <.empty_state_icon name={@icon} />
      </div>
      <div class="text-stone-300 text-2xl mt-5 select-none cursor-default">
        {@title}
      </div>
      <div :if={@inner_block != []} class="text-stone-400 text-sm mt-3 max-w-md text-center">
        {render_slot(@inner_block)}
      </div>
      <div :if={@action != []} class="mt-8">
        {render_slot(@action)}
      </div>
      <div class="w-12 mt-16 mx-auto border-t border-stone-100"></div>
    </div>
    """
  end

  defp empty_state_icon(%{name: "upload"} = assigns) do
    ~H"""
    <.animated_icon
      name="upload"
      class="w-24 h-24 opacity-30 invert grayscale"
      speed="1"
    />
    """
  end

  defp empty_state_icon(%{name: "folder"} = assigns) do
    ~H"""
    <.animated_icon
      name="upload"
      class="w-24 h-24 opacity-30 invert grayscale"
      speed="1"
    />
    """
  end

  defp empty_state_icon(assigns) do
    ~H"""
    <.animated_icon
      name="upload"
      class="w-24 h-24 opacity-30 invert grayscale"
      speed="1"
    />
    """
  end

  # =============================================================================
  # BREADCRUMB NAVIGATION
  # =============================================================================

  @doc """
  Breadcrumb navigation items with chevron separators.

  This renders just the inline breadcrumb items. Wrap it in a bar container
  at the page level for full-width styling.

  ## Examples

      <.breadcrumb>
        <:item navigate="/videos" label="Video" />
        <:item label="Archive" />
      </.breadcrumb>

  ## With wrapper bar (for page layout)

      <div class="flex-none w-full h-9 z-20 -mb-5 bg-white border-b border-stone-200/40">
        <div class="w-full h-full max-w-screen-xl mx-auto px-[3.75rem] opacity-70">
          <div class="w-full h-full flex items-center text-[0.79rem] text-stone-400">
            <.breadcrumb>
              <:item navigate="/videos" label="Video" />
              <:item label="Archive" />
            </.breadcrumb>
          </div>
        </div>
      </div>
  """
  attr :class, :string, default: nil

  slot :item, required: true do
    attr :navigate, :string
    attr :label, :string, required: true
    attr :id, :string
    attr :hook, :string
    attr :drop_to, :string
    attr :class, :string
  end

  def breadcrumb(assigns) do
    ~H"""
    <div class={["flex items-center text-[0.79rem] text-stone-400", @class]}>
      <%= for {item, index} <- Enum.with_index(@item) do %>
        <.link
          :if={item[:navigate]}
          navigate={item[:navigate]}
          class="flex items-center px-1.5 py-1 cursor-pointer rounded-md hover:bg-blue-50 ring-1 ring-inset ring-transparent"
        >
          <%= if item[:inner_block] do %>
            {render_slot(item)}
          <% else %>
            {item.label}
          <% end %>
        </.link>
        <div
          :if={!item[:navigate]}
          class="flex items-center px-1.5 py-1 rounded-md"
        >
          <%= if item[:inner_block] do %>
            {render_slot(item)}
          <% else %>
            {item.label}
          <% end %>
        </div>
        <div :if={index < length(@item) - 1}>
          <svg
            class="w-[1.1rem] h-[1.1rem] opacity-60"
            width="24px"
            height="24px"
            stroke-width="1.3"
            viewBox="0 0 24 24"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
            color="currentColor"
          >
            <path
              d="M9 6l6 6-6 6"
              stroke="currentColor"
              stroke-width="1.3"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
            </path>
          </svg>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Breadcrumb bar wrapper for page layouts.

  Full-width white bar that contains breadcrumb navigation.
  Use this at the page level before your main content.

  ## Example

      <.breadcrumb_bar>
        <:item navigate="/videos" label="Video" />
        <:item label="Archive" />
      </.breadcrumb_bar>
  """
  attr :class, :string, default: nil

  slot :item, required: true do
    attr :navigate, :string
    attr :label, :string, required: true
  end

  def breadcrumb_bar(assigns) do
    ~H"""
    <div class={["flex-none w-full h-9 z-20 -mb-5 bg-white border-b border-stone-200/40", @class]}>
      <div class="w-full h-full max-w-screen-xl mx-auto px-[3.75rem] opacity-70">
        <div class="w-full h-full flex items-center text-[0.79rem] text-stone-400">
          <%= for {item, index} <- Enum.with_index(@item) do %>
            <.link
              :if={item[:navigate]}
              id={item[:id]}
              phx-hook={item[:hook]}
              data-drop-target-id={item[:drop_to]}
              navigate={item[:navigate]}
              class={[
                "flex items-center px-1.5 py-1 cursor-pointer rounded-md hover:bg-blue-50 ring-1 ring-inset ring-transparent",
                item[:class]
              ]}
            >
              <%= if item[:inner_block] do %>
                {render_slot(item)}
              <% else %>
                {item.label}
              <% end %>
            </.link>
            <div
              :if={!item[:navigate]}
              id={item[:id]}
              phx-hook={item[:hook]}
              data-drop-target-id={item[:drop_to]}
              class={["flex items-center px-1.5 py-1 rounded-md", item[:class]]}
            >
              <%= if item[:inner_block] do %>
                {render_slot(item)}
              <% else %>
                {item.label}
              <% end %>
            </div>
            <div :if={index < length(@item) - 1}>
              <svg
                class="w-[1.1rem] h-[1.1rem] opacity-60"
                width="24px"
                height="24px"
                stroke-width="1.3"
                viewBox="0 0 24 24"
                fill="none"
                xmlns="http://www.w3.org/2000/svg"
                color="currentColor"
              >
                <path
                  d="M9 6l6 6-6 6"
                  stroke="currentColor"
                  stroke-width="1.3"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                >
                </path>
              </svg>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # USAGE BAR
  # =============================================================================

  @doc """
  Simple usage/quota progress bar for billing and settings pages.

  ## Examples

      <.usage_bar label="Video" current="12,450 embeds" max="50,000 embeds" percent={25} />
      <.usage_bar label="Bandwidth" current="18.2 GB" max="100 GB" percent={18.2} />
  """
  attr :label, :string, required: true
  attr :current, :string, required: true
  attr :max, :string, required: true
  attr :percent, :float, required: true
  attr :class, :string, default: nil

  def usage_bar(assigns) do
    assigns = assign(assigns, :segments, usage_bar_segments(assigns.percent))

    ~H"""
    <div class={["flex-grow flex flex-col justify-center", @class]}>
      <div class="text-stone-500 text-sm">{@label}</div>
      <div class="flex w-full h-0.5 mt-2.5 mb-1.5 overflow-hidden bg-stone-50 rounded-full">
        <div
          data-usage-segment="within-limit"
          class="h-full bg-blue-500"
          style={"width: #{@segments.within_limit}%;"}
        >
        </div>
        <div
          :if={@segments.overage > 0}
          data-usage-segment="overage"
          class="h-full bg-red-500"
          style={"width: #{@segments.overage}%;"}
        >
        </div>
      </div>
      <div class="flex text-stone-300 text-sm">
        <div class="flex-grow">{@current}</div>
        <div>{@max}</div>
      </div>
    </div>
    """
  end

  defp usage_bar_segments(percent) when percent > 100 do
    within_limit = Float.round(10_000.0 / percent, 4)
    %{within_limit: within_limit, overage: Float.round(100.0 - within_limit, 4)}
  end

  defp usage_bar_segments(percent) do
    %{within_limit: max(0, percent), overage: 0}
  end

  # =============================================================================
  # PROGRESS BAR
  # =============================================================================

  @doc """
  Encoding/processing progress bar with animated glow at the head.

  ## Examples

      <.progress_bar progress={75} />
      <.progress_bar progress={0} />
      <.progress_bar progress={100} />
  """
  attr :progress, :integer, default: 0
  attr :size, :string, values: ~w(sm md), default: "sm"
  attr :class, :string, default: nil

  def progress_bar(assigns) do
    ~H"""
    <div class={[
      "w-full rounded-full bg-black/15",
      @size == "sm" && "h-0.5",
      @size == "md" && "h-1",
      @class
    ]}>
      <div
        class={[
          "relative h-full rounded-full bg-blue-600 transition-all ease-out duration-125",
          @progress == 0 && "hidden"
        ]}
        style={"width: #{@progress}%;"}
      >
        <div class="absolute right-0 animate-pulse transform-gpu">
          <div class="absolute w-0.5 h-0.5 bg-blue-100 blur-sm"></div>
          <div class="absolute w-0.5 h-0.5 bg-blue-100 blur-md"></div>
          <div class="absolute w-0.5 h-0.5 bg-blue-100 blur-lg"></div>
          <div class="absolute w-0.5 h-0.5 bg-white rounded-full"></div>
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # LED INDICATOR
  # =============================================================================

  @doc """
  Small LED status indicator dot showing processing state.

  ## Examples

      <.led_indicator status={:complete} />
      <.led_indicator status={:processing} />
      <.led_indicator status={:queued} />
      <.led_indicator status={:none} />
  """
  attr :status, :atom, values: [:complete, :processing, :queued, :none], default: :none
  attr :class, :string, default: nil

  def led_indicator(%{status: :complete} = assigns) do
    ~H"""
    <div class={[
      "w-2 h-2 rounded-full bg-gradient-to-b from-green-400 to-green-600 flex-none",
      @class
    ]}>
    </div>
    """
  end

  def led_indicator(%{status: :processing} = assigns) do
    ~H"""
    <div class={[
      "relative w-2 h-2 rounded-full bg-stone-900 ring-1 ring-stone-700/60 flex-none",
      @class
    ]}>
      <div class="absolute -top-0.5 -left-0.5 w-[0.75rem] h-[0.75rem] ring-[0.1rem] ring-inset ring-blue-600 rounded-full flex-none animate-spin">
        <div class="w-[0.4rem] h-[0.4rem] bg-gradient-to-t from-stone-900 border-b-2 border-stone-900">
        </div>
      </div>
    </div>
    """
  end

  def led_indicator(%{status: :queued} = assigns) do
    ~H"""
    <div class={["w-2 h-2 rounded-full bg-black ring-1 ring-stone-700/60 flex-none", @class]}></div>
    """
  end

  def led_indicator(assigns) do
    ~H"""
    <div class={["w-2 h-2 rounded-full bg-black ring-1 ring-stone-700/60 flex-none", @class]}></div>
    """
  end

  # =============================================================================
  # RENDITION BADGE
  # =============================================================================

  @doc """
  Small badge/pill showing codec, size, or format information.

  ## Examples

      <.rendition_badge label="H.264" />
      <.rendition_badge label="1080p" variant="filled" />
      <.rendition_badge label="HLS" />
  """
  attr :label, :string, required: true
  attr :variant, :string, values: ~w(outline filled), default: "outline"
  attr :class, :string, default: nil

  def rendition_badge(assigns) do
    ~H"""
    <div class={[
      "w-10 font-condensed text-center rounded text-xs text-stone-600/80 px-1 pt-[0.02rem] pb-[0.09rem]",
      @variant == "outline" && "ring-1 ring-inset ring-stone-700/50 shadow",
      @variant == "filled" && "bg-stone-800 ring-1 ring-inset ring-stone-700/50 shadow",
      @class
    ]}>
      {@label}
    </div>
    """
  end
end
