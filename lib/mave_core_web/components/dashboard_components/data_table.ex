defmodule MaveCoreWeb.DashboardComponents.DataTable do
  @moduledoc """
  Data table components for the dashboard UI.
  """

  use Phoenix.Component

  # =============================================================================
  # DATA TABLE COMPONENTS
  # =============================================================================

  @doc """
  Responsive grid table container for dense dashboard data.

  The header and rows share the same `columns` class. At desktop widths the
  content is rendered as a conventional grid table. Below the `@5xl` container
  breakpoint, headers are hidden and rows stack into labeled cells instead of
  introducing a horizontal page-level scrollbar. Container queries make this
  work in narrow dashboard panels and Storybook previews, independent of the
  browser viewport width.

  ## Examples

      <.data_table_grid
        id="spaces-table"
        columns="@5xl:grid-cols-[minmax(16rem,2fr)_minmax(12rem,1fr)_8rem]"
      >
        <:header>
          <.data_table_grid_header_cell>Space</.data_table_grid_header_cell>
          <.data_table_grid_header_cell>Usage</.data_table_grid_header_cell>
          <.data_table_grid_header_cell>Created</.data_table_grid_header_cell>
        </:header>
        <.data_table_grid_row
          columns="@5xl:grid-cols-[minmax(16rem,2fr)_minmax(12rem,1fr)_8rem]"
        >
          <.data_table_grid_cell label="Space">example.com</.data_table_grid_cell>
          <.data_table_grid_cell label="Usage">12 videos</.data_table_grid_cell>
          <.data_table_grid_cell label="Created">2026-07-30</.data_table_grid_cell>
        </.data_table_grid_row>
      </.data_table_grid>
  """
  attr :id, :string, default: nil
  attr :columns, :any, required: true
  attr :class, :any, default: nil
  attr :header_class, :any, default: nil
  attr :rest, :global
  slot :header
  slot :inner_block, required: true

  def data_table_grid(assigns) do
    ~H"""
    <div
      id={@id}
      role="table"
      class={[
        "@container relative w-full rounded-md bg-white shadow-sm ring-1 ring-stone-200/60",
        @class
      ]}
      {@rest}
    >
      <div
        :if={@header != []}
        role="row"
        class={[
          "hidden gap-4 rounded-t-md border-b border-stone-200/60 bg-stone-50 px-6 py-3 text-xs uppercase tracking-wide text-stone-400 @5xl:grid",
          @columns,
          @header_class
        ]}
      >
        {render_slot(@header)}
      </div>
      <div role="rowgroup">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  A responsive row for `data_table_grid/1`.

  Use the same `columns` value as the parent grid. Rows stack below `@5xl`.
  """
  attr :id, :string, default: nil
  attr :columns, :any, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def data_table_grid_row(assigns) do
    ~H"""
    <div
      id={@id}
      role="row"
      class={[
        "grid grid-cols-1 gap-4 border-b border-stone-200/40 px-6 py-4 text-sm text-stone-500 last:border-b-0",
        @columns,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A desktop header cell for `data_table_grid/1`.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def data_table_grid_header_cell(assigns) do
    ~H"""
    <div role="columnheader" class={["min-w-0", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A responsive cell for `data_table_grid_row/1`.

  `label` is shown only while the row is stacked, so the content remains
  understandable when the desktop header is hidden.
  """
  attr :label, :string, default: nil
  attr :class, :any, default: nil
  attr :content_class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def data_table_grid_cell(assigns) do
    ~H"""
    <div role="cell" class={["min-w-0", @class]} {@rest}>
      <div
        :if={@label}
        class="mb-1 text-[0.68rem] uppercase tracking-wide text-stone-300 @5xl:hidden"
      >
        {@label}
      </div>
      <div class={@content_class}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Data table container with rounded border styling.

  ## Examples

      <.data_table>
        <:header>
          <.data_table_header_cell width="12rem">Name</.data_table_header_cell>
          <.data_table_header_cell width="8rem">Email</.data_table_header_cell>
        </:header>
        <.data_table_row>
          <.data_table_cell width="12rem">John Doe</.data_table_cell>
          <.data_table_cell width="8rem">john@example.com</.data_table_cell>
        </.data_table_row>
      </.data_table>
  """
  slot :header
  slot :inner_block, required: true

  def data_table(assigns) do
    ~H"""
    <div class="border rounded-md border-stone-200/50">
      <div :if={@header != []} class="w-full flex py-2.5 border-b border-stone-100">
        {render_slot(@header)}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Header cell for data table with configurable width and alignment.

  ## Examples

      <.data_table_header_cell width="12rem">Name</.data_table_header_cell>
      <.data_table_header_cell width="8rem" align="right">Actions</.data_table_header_cell>
  """
  attr :width, :string, default: nil
  attr :min_width, :string, default: nil
  attr :align, :string, values: ~w(left right center), default: "left"
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def data_table_header_cell(assigns) do
    style =
      [
        assigns.width && "width: #{assigns.width};",
        assigns.min_width && "min-width: #{assigns.min_width};"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns = assign(assigns, :computed_style, style)

    ~H"""
    <div
      class={[
        "text-sm text-stone-300 px-2 flex items-center",
        @align == "right" && "justify-end text-right",
        @align == "center" && "justify-center text-center",
        @class
      ]}
      style={@computed_style}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Data row with optional actions slot.

  ## Examples

      <.data_table_row id="member-1">
        <.data_table_cell>John Doe</.data_table_cell>
        <:actions>
          <.dash_button icon="delete">remove</.dash_button>
        </:actions>
      </.data_table_row>
  """
  attr :id, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def data_table_row(assigns) do
    ~H"""
    <div id={@id} class="w-full flex items-center border-b border-stone-100 last:border-none">
      <div class="w-full p-3.5 text-stone-400 text-sm cursor-default flex items-center">
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="flex items-center">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Cell for data table rows with configurable width.

  ## Examples

      <.data_table_cell width="12rem">John Doe</.data_table_cell>
      <.data_table_cell width="8rem" truncate>very-long-email@example.com</.data_table_cell>
  """
  attr :width, :string, default: nil
  attr :min_width, :string, default: nil
  attr :truncate, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def data_table_cell(assigns) do
    style =
      [
        assigns.width && "width: #{assigns.width};",
        assigns.min_width && "min-width: #{assigns.min_width};"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    assigns = assign(assigns, :computed_style, style)

    ~H"""
    <div
      class={[
        "text-sm text-stone-300 px-2 select-text flex items-center h-6",
        @truncate && "truncate",
        @class
      ]}
      style={@computed_style}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Colored avatar circle with initials - used for team member lists.

  ## Examples

      <.data_avatar initials="JD" color="blue" />
      <.data_avatar initials="AB" color="red" />
  """
  attr :initials, :string, required: true
  attr :color, :string, default: "blue"

  def data_avatar(assigns) do
    ~H"""
    <div class="mr-3.5 w-6 h-6 relative">
      <div class={[
        "w-6 h-6 text-center py-1 rounded-full font-medium text-[0.9rem] leading-[1.05rem] uppercase ring-1",
        avatar_color_classes(@color)
      ]}>
        {@initials}
      </div>
    </div>
    """
  end

  # Avatar color helpers to avoid dynamic class issues with Tailwind
  defp avatar_color_classes("red"), do: "bg-red-100/50 ring-red-200/50 text-red-300/60"

  defp avatar_color_classes("orange"),
    do: "bg-orange-100/50 ring-orange-200/50 text-orange-300/60"

  defp avatar_color_classes("amber"), do: "bg-amber-100/50 ring-amber-200/50 text-amber-300/60"

  defp avatar_color_classes("yellow"),
    do: "bg-yellow-100/50 ring-yellow-200/50 text-yellow-300/60"

  defp avatar_color_classes("lime"), do: "bg-lime-100/50 ring-lime-200/50 text-lime-300/60"
  defp avatar_color_classes("green"), do: "bg-green-100/50 ring-green-200/50 text-green-300/60"

  defp avatar_color_classes("emerald"),
    do: "bg-emerald-100/50 ring-emerald-200/50 text-emerald-300/60"

  defp avatar_color_classes("teal"), do: "bg-teal-100/50 ring-teal-200/50 text-teal-300/60"
  defp avatar_color_classes("cyan"), do: "bg-cyan-100/50 ring-cyan-200/50 text-cyan-300/60"
  defp avatar_color_classes("sky"), do: "bg-sky-100/50 ring-sky-200/50 text-sky-300/60"
  defp avatar_color_classes("blue"), do: "bg-blue-100/50 ring-blue-200/50 text-blue-300/60"

  defp avatar_color_classes("indigo"),
    do: "bg-indigo-100/50 ring-indigo-200/50 text-indigo-300/60"

  defp avatar_color_classes("violet"),
    do: "bg-violet-100/50 ring-violet-200/50 text-violet-300/60"

  defp avatar_color_classes("purple"),
    do: "bg-purple-100/50 ring-purple-200/50 text-purple-300/60"

  defp avatar_color_classes("fuchsia"),
    do: "bg-fuchsia-100/50 ring-fuchsia-200/50 text-fuchsia-300/60"

  defp avatar_color_classes("pink"), do: "bg-pink-100/50 ring-pink-200/50 text-pink-300/60"
  defp avatar_color_classes("rose"), do: "bg-rose-100/50 ring-rose-200/50 text-rose-300/60"
  defp avatar_color_classes("stone"), do: "bg-stone-100/50 ring-stone-200/50 text-stone-300/60"
  defp avatar_color_classes(_), do: "bg-blue-100/50 ring-blue-200/50 text-blue-300/60"

  # =============================================================================
  # TOGGLE SWITCH COMPONENT
  # =============================================================================

  @doc """
  Toggle switch - matches the ManageUI toggle styling.

  A sliding toggle switch that can be enabled/disabled. Supports click actions
  via phx-click and can be visually disabled.

  ## Examples

      <.toggle enabled={true} />
      <.toggle enabled={false} phx-click="toggle_feature" phx-target={@myself} />
      <.toggle enabled={@feature_enabled} disabled={true} />
  """
  attr :enabled, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-target phx-value-id)

  def toggle(assigns) do
    ~H"""
    <div
      class={[
        "ml-auto w-10 ring-1 ring-black/5 p-0.5 rounded-full cursor-pointer",
        "transform hover:scale-110 transition duration-150 ease-out",
        @enabled && "bg-blue-500 hover:ring-white",
        !@enabled && "bg-stone-100 hover:ring-stone-300",
        @disabled && "pointer-events-none opacity-60"
      ]}
      {@rest}
    >
      <div class={[
        "w-4 h-4 rounded-full bg-white transition duration-150",
        @enabled && "translate-x-5"
      ]}>
      </div>
    </div>
    """
  end
end
