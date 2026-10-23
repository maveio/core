defmodule MaveCoreWeb.ConnectionComponents do
  @moduledoc "Shared browser authorization layout for CLI and MCP connections."
  use MaveCoreWeb, :html
  import MaveCoreWeb.DashboardComponents, only: [animated_icon: 1]

  attr :id, :string, required: true
  attr :title_id, :string, required: true
  attr :title, :string, required: true
  attr :eyebrow, :string, required: true
  attr :footer, :string, required: true
  slot :inner_block, required: true

  def connection_card(assigns) do
    ~H"""
    <main
      id={@id}
      class="relative isolate flex min-h-svh w-full flex-col items-center bg-stone-100 px-4 py-8 text-stone-700"
      style="font-family: var(--font-sans); color-scheme: light;"
    >
      <section
        aria-labelledby={@title_id}
        class="relative z-10 my-auto flex w-full max-w-sm flex-col items-center rounded-md border border-white border-opacity-50 bg-stone-50 px-8 py-2 shadow-sm shadow-stone-200 ring-1 ring-stone-300 ring-opacity-50"
      >
        <div class="mx-auto mb-4 mt-8 size-24 rounded-full bg-white shadow-stone-200 ring-1 ring-stone-300 ring-opacity-40 transition hover:scale-105 hover:shadow-md">
          <.animated_icon name="link" class="size-full p-3 opacity-25" speed="1" />
        </div>
        <div class="mb-6 text-center">
          <p class="text-xs font-medium uppercase tracking-[0.18em] text-blue-400">{@eyebrow}</p>
          <h1 id={@title_id} class="mt-2 text-lg font-medium text-stone-700">{@title}</h1>
        </div>
        <div class="w-full">{render_slot(@inner_block)}</div>
        <div class="mb-5 mt-4 text-center text-[0.65rem] leading-4 text-stone-400 text-opacity-70">
          {@footer}
        </div>
      </section>
      <div
        aria-hidden="true"
        class="pointer-events-none fixed -bottom-28 mx-auto h-72 w-full max-w-screen-xl pt-0"
      >
        <div class="absolute z-10 hidden size-full bg-opacity-50 xl:flex">
          <div class="h-full w-72 bg-gradient-to-r from-stone-100"></div>
          <div class="flex-grow"></div>
          <div class="h-full w-72 bg-gradient-to-l from-stone-100"></div>
        </div>
        <.animated_icon
          name="waves"
          class="size-full rotate-180 grayscale opacity-10 contrast-200"
          speed="0.5"
          loop
        />
      </div>
    </main>
    """
  end
end
