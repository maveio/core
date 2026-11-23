defmodule MaveCoreWeb.DashboardComponents.Modals do
  @moduledoc """
  Modal and dialog components for the dashboard UI.
  """

  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  import MaveCoreWeb.DashboardComponents.Buttons
  import MaveCoreWeb.DashboardComponents.AnimatedIcon

  alias Phoenix.LiveView.JS

  # =============================================================================
  # MODAL - Exact ManageUI.modal classes
  # =============================================================================

  @doc """
  Slide-in modal - exact ManageUI.modal classes.
  """
  attr :show, :boolean, required: true
  attr :title, :string, required: true
  attr :on_cancel, JS, required: true
  attr :id, :string, default: "modal"
  attr :static, :boolean, default: false, doc: "Use static positioning (for storybook preview)"
  attr :panel_class, :string, default: "w-96"
  attr :theme, :string, values: ~w(light dark), default: "light"
  attr :resizable, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :interactive_background, :boolean, default: false
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      hidden
      phx-mounted={JS.remove_attribute("hidden")}
      phx-remove={
        @interactive_background &&
          JS.hide(
            to: "##{@id}-panel",
            transition: {"transition ease-out duration-200", "translate-x-0", "translate-x-full"},
            time: 200
          )
          |> JS.hide(
            transition: {"transition ease-out duration-200", "opacity-100", "opacity-0"},
            time: 200
          )
      }
      class={[
        @static && "relative w-full h-96 flex flex-cols",
        !@static && "fixed top-0 left-0 w-full h-full flex flex-cols z-60",
        !@interactive_background && "bg-stone-900/50",
        @interactive_background && "pointer-events-none starting:opacity-0",
        "transition ease-out duration-200",
        @show && "opacity-100",
        !@show && "opacity-0 pointer-events-none"
      ]}
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class="flex-grow"></div>
      <div
        id={(@resizable || @interactive_background) && "#{@id}-panel"}
        phx-hook={@resizable && "modal_resize"}
        class={[
          "border-l shadow-lg",
          @interactive_background && "pointer-events-auto starting:translate-x-full",
          if(@compact, do: "flex h-full min-h-0 flex-col overflow-hidden", else: "overflow-scroll"),
          @theme == "light" && "bg-white border-stone-200 border-opacity-70",
          @theme == "dark" && "bg-stone-900 border-stone-800 text-stone-200",
          @panel_class,
          @resizable && "relative",
          "transition ease-out duration-200",
          @show && "translate-x-0",
          !@show && "translate-x-full"
        ]}
        phx-click-away={if !@interactive_background, do: @on_cancel}
      >
        <div
          :if={@resizable}
          id={"#{@id}-resize"}
          phx-update="ignore"
          role="separator"
          tabindex="0"
          aria-orientation="vertical"
          aria-label={gettext("Resize editor panel")}
          title={gettext("Resize editor panel")}
          class="absolute inset-y-0 left-0 z-10 hidden w-3 cursor-ew-resize touch-none select-none border-l-2 border-transparent transition-colors hover:border-blue-400/50 focus-visible:border-blue-400 focus-visible:outline-none active:border-blue-400 sm:block"
        />
        <div
          :if={!@compact}
          class={[
            "w-full shrink-0 border-b",
            @theme == "light" && "bg-stone-100 border-stone-200 border-opacity-70",
            @theme == "dark" && "bg-stone-900 border-stone-800"
          ]}
        >
          <div class="w-full h-16"></div>
        </div>
        <div class={[
          "w-full shrink-0 border-b",
          @theme == "light" && "bg-stone-100 border-stone-200 border-opacity-70",
          @theme == "dark" && "bg-stone-900 border-stone-800"
        ]}>
          <div class={[
            "w-full h-16 flex items-center",
            if(@compact, do: "px-5", else: "px-16")
          ]}>
            <div class={[
              "flex-grow text-2xl border-b border-transparent font-medium pt-0.5 hover:cursor-default",
              if(@theme == "dark", do: "text-stone-100", else: "text-stone-600")
            ]}>
              {@title}
            </div>
          </div>
        </div>
        <div class={if(@compact, do: "min-h-0 flex-1 px-5", else: "px-16 py-14")}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # =============================================================================
  # DIALOG - ManageUI.dialog style
  # =============================================================================

  @doc """
  Confirmation dialog.
  """
  attr :show, :boolean, required: true
  attr :title, :string, default: nil
  attr :on_confirm, JS, required: true
  attr :on_cancel, JS, required: true
  attr :loading_on_confirm, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :id, :string, default: "dialog"
  attr :confirm_label, :string, default: nil
  attr :cancel_label, :string, default: nil

  attr :confirm_variant, :string,
    values: ~w(default primary ghost danger),
    default: "default"

  attr :static, :boolean, default: false, doc: "Use static positioning (for storybook preview)"
  slot :inner_block

  def dialog(assigns) do
    assigns = assign(assigns, :resolved_title, assigns.title || gettext("Are you sure?"))

    ~H"""
    <div
      id={@id}
      class={[
        @static && "relative py-8 flex items-center justify-center bg-stone-100 bg-opacity-95",
        !@static &&
          "fixed top-0 left-0 w-full h-full bg-stone-100 backdrop-filter backdrop-blur-xl bg-opacity-95 z-60 flex items-center justify-center",
        "transition duration-125",
        @show && "opacity-100",
        !@show && "opacity-0 pointer-events-none"
      ]}
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div
        class={[
          "bg-stone-50 ring-1 ring-stone-300 border border-white border-opacity-50 ring-opacity-50 rounded-md shadow-sm shadow-stone-200",
          "flex flex-col items-center p-6",
          "transition-all ease-out duration-200",
          "scale-75",
          @show && "opacity-100 scale-100",
          !@show && "opacity-0 pointer-events-none",
          @disabled && "opacity-80 pointer-events-none"
        ]}
        phx-click-away={@on_cancel}
      >
        <div class="mx-auto my-6 w-28 h-28 bg-white ring-1 ring-stone-300 ring-opacity-40 rounded-full transition hover:scale-105 hover:shadow-md hover:shadow-stone-200 flex items-center justify-center">
          <.animated_icon
            :if={@show}
            name="warning"
            class="w-16 h-16"
            speed="1.5"
          />
        </div>

        <div class="text-xl font-medium text-stone-700 mt-4">
          {@resolved_title}
        </div>

        <div class="text-stone-400 text-sm mt-4 max-w-[16rem] mx-auto text-center">
          <%= if @inner_block != [] do %>
            {render_slot(@inner_block)}
          <% else %>
            {gettext("This action cannot be reversed.")}
          <% end %>
        </div>

        <div class="flex items-center mt-16 mx-12 w-full">
          <.dash_button
            id={"#{@id}-cancel"}
            phx-click={@on_cancel}
            disabled={@disabled}
          >
            {@cancel_label || gettext("cancel")}
          </.dash_button>
          <div class="flex-grow" />
          <.dash_button
            id={"#{@id}-confirm"}
            phx-click={@on_confirm}
            disabled={@disabled}
            loading_on_click={@loading_on_confirm}
            variant={@confirm_variant}
          >
            {@confirm_label || gettext("confirm")}
          </.dash_button>
        </div>
      </div>
    </div>
    """
  end
end
