defmodule MaveCoreWeb.DashboardComponents.Inputs do
  @moduledoc """
  Input and form components for the dashboard UI.
  """

  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  # =============================================================================
  # INPUT COMPONENTS - Exact ManageUI classes
  # =============================================================================

  @doc """
  Shared dashboard text input.
  """
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :type, :string, default: "text"
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(phx-target phx-blur phx-debounce autocomplete)

  def dash_input(assigns) do
    ~H"""
    <div class="w-full min-w-0">
      <.error_tag :if={@field} field={@field} />
      <div class={[
        "group w-full rounded-md bg-white",
        "border border-stone-200 md:border-none",
        "ring-1 ring-stone-200/50",
        "md:shadow-sm shadow-stone-200",
        "focus-within:ring-blue-500 focus-within:ring-1",
        "hover:shadow-md hover:shadow-stone-100",
        "transition ease-out transform-gpu hover:scale-105 duration-150",
        @disabled && "opacity-50 pointer-events-none",
        @class
      ]}>
        <input
          type={@type}
          name={(@field && @field.name) || @name}
          id={(@field && @field.id) || @name}
          value={(@field && @field.value) || @value}
          placeholder={@placeholder}
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
          spellcheck="false"
          disabled={@disabled}
          class={[
            "w-full rounded-md bg-transparent border-0 ring-0",
            "placeholder-stone-400 md:text-[0.96rem] text-stone-700",
            "px-4 py-2.5 cursor-pointer outline-none",
            "focus:ring-0 focus:outline-none",
            "origin-left transition ease-out transform-gpu duration-150",
            "group-hover:scale-[0.952381]"
          ]}
          {@rest}
        />
      </div>
    </div>
    """
  end

  @doc """
  Shared dashboard select dropdown.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(phx-target phx-blur)

  def dash_select(assigns) do
    ~H"""
    <div>
      <.error_tag field={@field} />
      <div class={[
        "group w-full rounded-md bg-white",
        "border border-stone-200 md:border-none",
        "ring-1 ring-stone-200/50",
        "md:shadow-sm shadow-stone-200",
        "focus-within:ring-blue-500 focus-within:ring-1",
        "hover:shadow-md hover:shadow-stone-100",
        "transition ease-out transform-gpu hover:scale-105 duration-150",
        @disabled && "opacity-50 pointer-events-none",
        @class
      ]}>
        <select
          name={@field.name}
          id={@field.id}
          disabled={@disabled}
          class={[
            "appearance-none w-full rounded-md bg-transparent border-0 ring-0",
            "md:text-[0.96rem] text-stone-400 focus:text-stone-700",
            "px-4 py-2.5 cursor-pointer outline-none",
            "focus:ring-0 focus:outline-none",
            "origin-left transition ease-out transform-gpu duration-150",
            "group-hover:scale-[0.952381]"
          ]}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @field.value)}
        </select>
      </div>
    </div>
    """
  end

  @doc """
  Error tag - exact MaveWeb.ErrorHelpers.error_tag styling.
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def error_tag(assigns) do
    ~H"""
    <div class={[
      "transition-all duration-150 ease-out",
      @field.errors != [] && "overflow-visible mb-2",
      @field.errors == [] && "h-0 overflow-hidden"
    ]}>
      <div
        :if={@field.errors != []}
        class="flex -mb-1 border-transparent mx-3 items-center min-w-0"
      >
        <div class="text-rose-400">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-4 h-4"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.7"
            stroke-linecap="round"
            stroke-linejoin="round"
          >
            <polyline points="14 15 9 20 4 15"></polyline>
            <path d="M20 4h-7a4 4 0 0 0-4 4v12"></path>
          </svg>
        </div>
        <div class="text-rose-400 mx-1.5 text-sm mb-3 min-w-0 flex-1 break-words">
          {translate_error(Enum.at(@field.errors, 0))}
        </div>
      </div>
    </div>
    """
  end

  defp translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(MaveCoreWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MaveCoreWeb.Gettext, "errors", msg, opts)
    end
  end

  defp translate_error(nil), do: ""
end
