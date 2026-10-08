defmodule MaveCoreWeb.DashboardComponents.Fields do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :active, :boolean, default: false
  attr :label, :string, default: nil
  attr :clickable, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def highlight_card(assigns) do
    ~H"""
    <div
      class={[
        "relative border rounded-lg",
        @active && "border-blue-300",
        !@active && "border-stone-200/50",
        !@active && @clickable && "hover:border-blue-300 cursor-pointer",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@active && @label}
        class="absolute w-full flex justify-center -top-3 border-t border-transparent"
      >
        <div class="px-1.5 py-0.5 bg-white text-blue-300 text-xs">{@label}</div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :name, :string, required: true
  attr :provider, :string, required: true
  attr :location, :string, required: true
  attr :logo_src, :string, default: nil
  attr :logo_alt, :string, default: ""
  attr :active, :boolean, required: true

  def region_card(assigns) do
    ~H"""
    <.highlight_card active={@active} label={gettext("current region")} class="rounded-md">
      <div class="flex items-center p-3">
        <img
          :if={@logo_src}
          src={@logo_src}
          class="w-4 h-4 ml-1 mr-4 rounded-full"
          alt={@logo_alt}
        />
        <div :if={!@logo_src} class="w-4 h-4 ml-1 mr-4 rounded-full bg-stone-100"></div>
        <div>
          <span class="text-sm text-stone-400 right">{@name}</span>
          <span class="text-sm text-stone-600">{@provider}</span>
          <div class="text-xs text-stone-400 my-1">{@location}</div>
        </div>
      </div>
    </.highlight_card>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true

  def copyable_field(assigns) do
    ~H"""
    <div class="flex items-center bg-stone-50 rounded text-sm text-stone-400 p-2.5 select-text">
      <div id={@id} class="flex-grow font-mono text-xs mr-2">{@value}</div>
      <.copy_button target={@id} />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :revealed, :boolean, default: false
  attr :on_toggle, :any, required: true
  attr :secret_name, :string, default: nil
  attr :rounded, :string, default: "rounded"
  attr :class, :string, default: nil

  def secret_field(assigns) do
    assigns = assign(assigns, :secret_name, assigns.secret_name || gettext("API key"))

    ~H"""
    <div class={[
      "flex h-11 items-center bg-stone-50 text-sm text-stone-400 p-2.5",
      @rounded,
      @class
    ]}>
      <div id={@id} class="min-w-0 flex-grow truncate font-mono text-xs mr-2">
        <span :if={@revealed} class="select-text">{@value}</span>
        <span
          :if={!@revealed}
          class="text-stone-400 select-none"
          aria-label={gettext("%{secret_name} hidden", secret_name: @secret_name)}
        >
          {masked_secret(@value)}
        </span>
      </div>
      <span id={"#{@id}-copy-value"} class="hidden" aria-hidden="true">{@value}</span>
      <button
        id={"#{@id}-toggle"}
        type="button"
        phx-click={@on_toggle}
        aria-pressed={to_string(@revealed)}
        aria-label={
          if @revealed,
            do: gettext("Hide %{secret_name}", secret_name: @secret_name),
            else: gettext("Reveal %{secret_name}", secret_name: @secret_name)
        }
        title={
          if @revealed,
            do: gettext("Hide %{secret_name}", secret_name: @secret_name),
            else: gettext("Reveal %{secret_name}", secret_name: @secret_name)
        }
        class="inline-flex size-6 flex-none items-center justify-center rounded text-stone-400 hover:text-blue-500 focus:outline-none focus-visible:ring-1 focus-visible:ring-blue-400 cursor-pointer transition duration-150 ease-out"
      >
        <MaveCoreWeb.DashboardComponents.Buttons.icon
          name={if @revealed, do: "hero-eye-slash", else: "hero-eye"}
          class="size-4"
        />
      </button>
      <.copy_button target={"#{@id}-copy-value"} />
    </div>
    """
  end

  attr :target, :string, required: true

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      aria-label={gettext("Copy to clipboard")}
      title={gettext("Copy to clipboard")}
      class="inline-flex size-6 flex-none items-center justify-center rounded text-stone-400 hover:text-blue-500 focus:outline-none focus-visible:ring-1 focus-visible:ring-blue-400 cursor-pointer transition duration-150 ease-out"
      phx-click={JS.dispatch("mave:clipcopy", to: "##{@target}")}
    >
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
        <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path>
        <rect x="8" y="2" width="8" height="4" rx="1" ry="1"></rect>
      </svg>
    </button>
    """
  end

  defp masked_secret(value) when is_binary(value) do
    "#{String.slice(value, 0, 7)}••••••••••••#{String.slice(value, -5, 5)}"
  end
end
