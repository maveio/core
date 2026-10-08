defmodule MaveCoreWeb.DashboardComponents.Media do
  @moduledoc """
  Media components for embed/folder list views in the dashboard UI.
  """

  use Phoenix.Component

  # =============================================================================
  # MEDIA COMPONENTS - For embed/folder list views
  # =============================================================================

  @doc """
  Unified media item row for both folders and video embeds.

  ## Examples

      <.media_item type={:video} name="My Video" thumbnail="/path/to/thumb.jpg" date="20 January 2026">
        <:badges>
          <.media_badge>1080p</.media_badge>
          <.media_badge>30fps</.media_badge>
        </:badges>
      </.media_item>

      <.media_item type={:folder} name="Archive" navigate="/videos/archive">
        <:badges>
          <.media_badge>12 videos</.media_badge>
        </:badges>
      </.media_item>
  """
  attr :type, :atom, values: [:video, :folder], default: :video
  attr :name, :string, required: true
  attr :thumbnail, :string, default: nil
  attr :date, :string, default: nil
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :draggable, :boolean, default: false
  attr :empty, :boolean, default: false
  attr :deleted, :boolean, default: false
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :badges
  slot :actions

  def media_item(assigns) do
    assigns =
      assign(
        assigns,
        :empty_video,
        assigns.type == :video and
          (assigns.empty or (is_nil(assigns.thumbnail) and assigns.badges == []))
      )

    ~H"""
    <div
      id={@id}
      draggable={if @draggable, do: "true"}
      class={[
        "flex border-b ring-1 ring-inset ring-transparent border-b-stone-100/60",
        "hover:border-transparent hover:rounded-xl hover:ring-blue-200",
        "active:bg-blue-100/50",
        "cursor-pointer select-none -mx-3.5 py-2 px-3.5 2xl:mr-0",
        @deleted && "hidden",
        @class
      ]}
      {@rest}
    >
      <.link :if={@navigate} navigate={@navigate} class="flex-none w-24 aspect-video py-2 z-0">
        <.media_thumbnail type={@type} thumbnail={@thumbnail} />
      </.link>
      <.link
        :if={!@navigate and @patch}
        patch={@patch}
        class="flex-none w-24 aspect-video py-2 z-0"
      >
        <.media_thumbnail type={@type} thumbnail={@thumbnail} />
      </.link>
      <div :if={!@navigate and !@patch} class="flex-none w-24 aspect-video py-2 z-0">
        <.media_thumbnail type={@type} thumbnail={@thumbnail} />
      </div>

      <.link
        :if={@navigate}
        navigate={@navigate}
        class={[
          "flex-grow px-4 ml-1",
          @empty_video && "flex items-center",
          !@empty_video && "flex flex-col justify-center"
        ]}
      >
        <div class={[
          "text-md text-sm",
          @thumbnail && "text-stone-600 mt-2",
          !@thumbnail && @type == :video && !@empty_video && "text-stone-300 mt-5",
          !@thumbnail && @type == :video && @empty_video && "text-stone-300 leading-none",
          !@thumbnail && @type != :video && "text-stone-600 mt-2"
        ]}>
          {@name}
        </div>
        <div :if={!@empty_video} class="flex pt-2 pb-1">
          {render_slot(@badges)}
          <div :if={@badges == []} class="mb-3"></div>
        </div>
      </.link>
      <.link
        :if={!@navigate and @patch}
        patch={@patch}
        class={[
          "flex-grow px-4 ml-1",
          @empty_video && "flex items-center",
          !@empty_video && "flex flex-col justify-center"
        ]}
      >
        <div class={[
          "text-md text-sm",
          @thumbnail && "text-stone-600 mt-2",
          !@thumbnail && @type == :video && !@empty_video && "text-stone-300 mt-5",
          !@thumbnail && @type == :video && @empty_video && "text-stone-300 leading-none",
          !@thumbnail && @type != :video && "text-stone-600 mt-2"
        ]}>
          {@name}
        </div>
        <div :if={!@empty_video} class="flex pt-2 pb-1">
          {render_slot(@badges)}
          <div :if={@badges == []} class="mb-3"></div>
        </div>
      </.link>
      <div
        :if={!@navigate and !@patch}
        class={[
          "flex-grow px-4 ml-1",
          @empty_video && "flex items-center",
          !@empty_video && "flex flex-col justify-center"
        ]}
      >
        <div class={[
          "text-md text-sm",
          @thumbnail && "text-stone-600 mt-2",
          !@thumbnail && @type == :video && !@empty_video && "text-stone-300 mt-5",
          !@thumbnail && @type == :video && @empty_video && "text-stone-300 leading-none",
          !@thumbnail && @type != :video && "text-stone-600 mt-2"
        ]}>
          {@name}
        </div>
        <div :if={!@empty_video} class="flex pt-2 pb-1">
          {render_slot(@badges)}
          <div :if={@badges == []} class="mb-3"></div>
        </div>
      </div>

      <div class="flex-none flex items-center">
        {render_slot(@actions)}
        <div :if={@date} class="text-sm text-stone-300 pr-1">{@date}</div>
      </div>
    </div>
    """
  end

  # Thumbnail rendering based on type
  defp media_thumbnail(%{type: :folder} = assigns) do
    ~H"""
    <div class="relative w-24 aspect-video bg-stone-50 rounded-b-md rounded-tr-md bg-cover bg-center bg-no-repeat ring-1 ring-inset ring-stone-200/40 flex items-center justify-center">
      <div class="absolute left-0 -top-1 w-8 h-1 bg-stone-100/80 rounded-tl-md rounded-tr-md"></div>
      <div class="w-2/3 h-full mx-auto grid grid-cols-2 gap-0.5 py-1.5 px-2">
        <div class="w-full h-full bg-stone-100 rounded-sm"></div>
        <div class="w-full h-full bg-stone-100 rounded-sm"></div>
        <div class="w-full h-full bg-stone-100 rounded-sm"></div>
        <div class="w-full h-full bg-stone-100 rounded-sm"></div>
      </div>
    </div>
    """
  end

  defp media_thumbnail(%{thumbnail: nil} = assigns) do
    ~H"""
    <div class="relative w-24 aspect-video bg-stone-50 rounded-md bg-cover bg-center bg-no-repeat overflow-hidden ring-1 ring-inset ring-stone-200/40 flex items-center justify-center">
      <svg
        class="w-10 h-10 text-stone-200"
        width="24"
        height="24"
        stroke-width="0.6"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path d="M6 20L18 20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" />
        <path
          d="M12 16V4M12 4L15.5 7.5M12 4L8.5 7.5"
          stroke="currentColor"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </div>
    """
  end

  defp media_thumbnail(assigns) do
    ~H"""
    <div class="w-24 aspect-video rounded-md overflow-hidden bg-stone-50 ring-1 ring-inset ring-stone-200/20">
      <div
        class="w-full h-full bg-center bg-no-repeat rounded-md"
        style={"background-image: url(#{@thumbnail}); background-size: 110%;"}
      >
      </div>
    </div>
    """
  end

  @doc """
  Simple metadata badge for resolution, fps, language, file count, etc.

  ## Examples

      <.media_badge>1080p</.media_badge>
      <.media_badge>EN</.media_badge>
      <.media_badge>30fps</.media_badge>
      <.media_badge>12 videos</.media_badge>
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def media_badge(assigns) do
    ~H"""
    <div class={[
      "font-condensed font-medium px-1 pb-0.5 my-1 bg-stone-100/80 text-stone-400 text-xs mr-1 rounded",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
