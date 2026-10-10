defmodule MaveCoreWeb.DashboardComponents.VideoDetail do
  @moduledoc """
  Shared building blocks for the dashboard video detail page.
  """

  use Phoenix.Component
  use Gettext, backend: MaveCoreWeb.Gettext

  import MaveCoreWeb.DashboardComponents.Navigation, only: [section_title: 1]
  import MaveCoreWeb.DashboardComponents.AnimatedIcon
  alias Phoenix.LiveView.JS

  attr :player_dom_id, :string, required: true
  attr :tabs, :list, required: true
  attr :snippet, :string, required: true
  attr :line_numbers, :list, required: true
  attr :audio_only, :boolean, default: false
  attr :change_event, :string, default: "change_code_preview"
  slot :player, required: true
  slot :guidance

  def video_embed_panel(assigns) do
    ~H"""
    <div class="w-full bg-stone-900">
      <div
        id={@player_dom_id}
        class={[
          "w-full bg-stone-900 flex items-center justify-center",
          !@audio_only && "min-h-[22rem]"
        ]}
      >
        {render_slot(@player)}
      </div>

      {render_slot(@guidance)}
      <div class="border-t border-stone-900 -mt-px">
        <div class="w-full bg-stone-900 flex items-center border-b border-stone-800 select-none">
          <.video_embed_tab :for={tab <- @tabs} tab={tab} change_event={@change_event} />
          <div class="flex-grow"></div>
        </div>
      </div>

      <.video_snippet snippet={@snippet} line_numbers={@line_numbers} />
    </div>
    """
  end

  attr :tab, :map, required: true
  attr :change_event, :string, default: "change_code_preview"

  def video_embed_tab(assigns) do
    ~H"""
    <div
      class={[
        "relative text-sm border-b w-[5rem] h-20 flex flex-col items-center justify-center",
        @tab.current && "text-stone-300 border-blue-600 cursor-default",
        !@tab.current && "border-transparent text-stone-500 hover:bg-stone-800 cursor-pointer"
      ]}
      phx-click={!@tab.current && @change_event}
      phx-value-preview={@tab.name}
    >
      <div class="w-12 h-8 flex items-center justify-center">
        <.video_embed_tab_icon name={@tab.name} />
      </div>
      <div class="pt-[0.2rem]">{@tab.label}</div>
    </div>
    """
  end

  attr :name, :atom, required: true

  def video_embed_tab_icon(%{name: :script} = assigns) do
    ~H"""
    <svg
      class="w-[1.85rem] h-[1.85rem] grayscale text-stone-400 opacity-40"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="0.8"
      stroke="currentColor"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.91 11.672a.375.375 0 010 .656l-5.603 3.113a.375.375 0 01-.557-.328V8.887c0-.286.307-.466.557-.327l5.603 3.112z"
      />
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M 4.5 19.5 h 15 a 2.25 2.25 0 0 0 2.25 -2.25 V 6.75 A 2.25 2.25 0 0 0 19.5 4.5 h -15 a 2.25 2.25 0 0 0 -2.25 2.25 v 10.5 A 2.25 2.25 0 0 0 4.5 19.5 z"
      />
    </svg>
    """
  end

  def video_embed_tab_icon(%{name: :clip} = assigns) do
    ~H"""
    <svg
      class="w-[1.85rem] h-[1.85rem] grayscale text-stone-400 opacity-40"
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="0.8"
      stroke="currentColor"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 001.5-1.5V6a1.5 1.5 0 00-1.5-1.5H3.75A1.5 1.5 0 002.25 6v12a1.5 1.5 0 001.5 1.5zm10.5-11.25h.008v.008h-.008V8.25zm.375 0a.375.375 0 11-.75 0 .375.375 0 01.75 0z"
      />
    </svg>
    """
  end

  def video_embed_tab_icon(%{name: :iframe} = assigns) do
    ~H"""
    <svg
      class="w-full h-full grayscale text-stone-300 opacity-25"
      width="24"
      height="24"
      stroke-width="0.9"
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path d="M13.5 6L10 18.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" />
      <path
        d="M6.5 8.5L3 12L6.5 15.5"
        stroke="currentColor"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <path
        d="M17.5 8.5L21 12L17.5 15.5"
        stroke="currentColor"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  def video_embed_tab_icon(%{name: :react} = assigns) do
    ~H"""
    <svg class="w-6 h-6 text-stone-400 opacity-30" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 10.11c1.03 0 1.87.84 1.87 1.89 0 1-.84 1.85-1.87 1.85S10.13 13 10.13 12c0-1.05.84-1.89 1.87-1.89M7.37 20c.63.38 2.01-.2 3.6-1.7-.52-.59-1.03-1.23-1.51-1.9a22.7 22.7 0 01-2.4-.36c-.51 2.14-.32 3.61.31 3.96m.71-5.74l-.29-.51c-.11.29-.22.58-.29.86.27.06.57.11.88.16l-.3-.51m6.54-.76l.81-1.5-.81-1.5c-.3-.53-.62-1-.91-1.47C13.17 9 12.6 9 12 9s-1.17 0-1.71.03c-.29.47-.61.94-.91 1.47L8.57 12l.81 1.5c.3.53.62 1 .91 1.47.54.03 1.11.03 1.71.03s1.17 0 1.71-.03c.29-.47.61-.94.91-1.47M12 6.78c-.19.22-.39.45-.59.72h1.18c-.2-.27-.4-.5-.59-.72m0 10.44c.19-.22.39-.45.59-.72h-1.18c.2.27.4.5.59.72M16.62 4c-.62-.38-2 .2-3.59 1.7.52.59 1.03 1.23 1.51 1.9.82.08 1.63.2 2.4.36.51-2.14.32-3.61-.32-3.96m-.7 5.74l.29.51c.11-.29.22-.58.29-.86-.27-.06-.57-.11-.88-.16l.3.51m1.45-7.05c1.47.84 1.63 3.05 1.01 5.63 2.54.75 4.37 1.99 4.37 3.68s-1.83 2.93-4.37 3.68c.62 2.58.46 4.79-1.01 5.63-1.46.84-3.45-.12-5.37-1.95-1.92 1.83-3.91 2.79-5.38 1.95-1.46-.84-1.62-3.05-1-5.63-2.54-.75-4.37-1.99-4.37-3.68s1.83-2.93 4.37-3.68c-.62-2.58-.46-4.79 1-5.63 1.47-.84 3.46.12 5.38 1.95 1.92-1.83 3.91-2.79 5.37-1.95M17.08 12c.34.75.64 1.5.89 2.26 2.1-.63 3.28-1.53 3.28-2.26s-1.18-1.63-3.28-2.26c-.25.76-.55 1.51-.89 2.26M6.92 12c-.34-.75-.64-1.5-.89-2.26-2.1.63-3.28 1.53-3.28 2.26s1.18 1.63 3.28 2.26c.25-.76.55-1.51.89-2.26m9 2.26l-.3.51c.31-.05.61-.1.88-.16-.07-.28-.18-.57-.29-.86l-.29.51m-2.89 4.04c1.59 1.5 2.97 2.08 3.59 1.7.64-.35.83-1.82.32-3.96-.77.16-1.58.28-2.4.36-.48.67-.99 1.31-1.51 1.9M8.08 9.74l.3-.51c-.31.05-.61.1-.88.16.07.28.18.57.29.86l.29-.51m2.89-4.04C9.38 4.2 8 3.62 7.37 4c-.63.35-.82 1.82-.31 3.96a22.7 22.7 0 012.4-.36c.48-.67.99-1.31 1.51-1.9z" />
    </svg>
    """
  end

  def video_embed_tab_icon(%{name: :vue} = assigns) do
    ~H"""
    <svg class="w-6 h-6 text-stone-400 opacity-30" viewBox="0 0 24 24" fill="currentColor">
      <path d="M2 3h3.5L12 15l6.5-12H22L12 21 2 3m4.5 0h3L12 8l2.5-5h3L12 13 6.5 3z" />
    </svg>
    """
  end

  attr :snippet, :string, required: true
  attr :line_numbers, :list, required: true

  def video_snippet(assigns) do
    ~H"""
    <code class="w-full relative font-mono py-3 select-text decoration-blue-500 leading-6 flex overflow-hidden text-[84%]">
      <div class="flex-none pl-3.5 w-8 mr-0.5 h-full text-right select-none text-stone-600">
        <div class="absolute">
          <div :for={n <- @line_numbers}><span>{n}</span></div>
        </div>
        <div class="absolute left-0 bottom-0 h-2 w-8 bg-stone-900"></div>
      </div>
      <div id="snippet-code" class="flex-grow text-stone-500 overflow-x-auto">
        {highlight_snippet(@snippet)}
      </div>
      <div class="flex-none flex mr-4">
        <div
          class="w-12 h-8 pr-0.5 bg-gradient-to-b from-stone-700 to-stone-900 rounded-full text-blue-400 flex items-center ring-1 ring-black border border-stone-700 justify-center transition ease-out cursor-pointer hover:ring-blue-500 hover:text-blue-500"
          phx-click={JS.dispatch("mave:clipcopy", to: "#snippet-code")}
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-full w-full p-0.5 border-l border-b border-transparent"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="1.1"
              d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01"
            />
          </svg>
        </div>
      </div>
    </code>
    """
  end

  # sobelow_skip ["XSS.Raw"]
  defp highlight_snippet(snippet) do
    snippet
    |> String.split("\n")
    |> Enum.map_join("\n", &highlight_snippet_line/1)
    |> then(&~s(<span class="highlight">#{&1}</span>))
    |> Phoenix.HTML.raw()
  end

  defp highlight_snippet_line(line) do
    complete_tag_regex = ~r/(<\/?)([A-Za-z][\w:-]*)([^>]*)(>)/
    open_tag_regex = ~r/^(<)([A-Za-z][\w:-]*)(.*)$/
    attr_continuation_regex = ~r/^\s+[A-Za-z_:][-A-Za-z0-9_:.]*(?:=|>|\s|$)/

    cond do
      Regex.match?(complete_tag_regex, line) ->
        replace_escaped_matches(complete_tag_regex, line, fn [_match, open, tag, attrs, close] ->
          [
            snippet_span("mave-snippet-punct", open),
            snippet_span("mave-snippet-tag", tag),
            highlight_snippet_attrs(attrs),
            snippet_span("mave-snippet-punct", close)
          ]
          |> IO.iodata_to_binary()
        end)

      Regex.match?(open_tag_regex, line) ->
        [_match, open, tag, attrs] = Regex.run(open_tag_regex, line)

        [
          snippet_span("mave-snippet-punct", open),
          snippet_span("mave-snippet-tag", tag),
          highlight_snippet_attrs(attrs)
        ]
        |> IO.iodata_to_binary()

      Regex.match?(attr_continuation_regex, line) ->
        highlight_snippet_attr_continuation(line)

      true ->
        html_escape(line)
    end
  end

  defp highlight_snippet_attr_continuation(line) do
    if String.ends_with?(line, ">") do
      line
      |> binary_part(0, byte_size(line) - 1)
      |> highlight_snippet_attrs()
      |> Kernel.<>(snippet_span("mave-snippet-punct", ">"))
    else
      highlight_snippet_attrs(line)
    end
  end

  defp highlight_snippet_attrs(attrs) do
    replace_escaped_matches(
      ~r/(\s+)([A-Za-z_:][-A-Za-z0-9_:.]*)(?:=("[^"]*"|'[^']*'|[^\s>]+))?/,
      attrs,
      fn
        [_match, space, name] ->
          [
            html_escape(space),
            snippet_span("mave-snippet-attr", name)
          ]
          |> IO.iodata_to_binary()

        [_match, space, name, value] ->
          [
            html_escape(space),
            snippet_span("mave-snippet-attr", name),
            snippet_span("mave-snippet-punct", "="),
            snippet_span("mave-snippet-value", value)
          ]
          |> IO.iodata_to_binary()
      end
    )
  end

  defp replace_escaped_matches(regex, text, highlight) do
    {parts, offset} =
      regex
      |> Regex.scan(text, return: :index)
      |> Enum.reduce({[], 0}, fn [{start, length} | _] = matches, {parts, offset} ->
        captures =
          Enum.map(matches, fn
            {-1, 0} -> ""
            {start, length} -> binary_part(text, start, length)
          end)

        gap = text |> binary_part(offset, start - offset) |> html_escape()
        {[parts, gap, highlight.(captures)], start + length}
      end)

    suffix = text |> binary_part(offset, byte_size(text) - offset) |> html_escape()
    IO.iodata_to_binary([parts, suffix])
  end

  defp snippet_span(class, value) do
    escaped =
      value
      |> html_escape()

    ~s(<span class="#{class}">#{escaped}</span>)
  end

  defp html_escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  attr :token, :string, required: true
  attr :hook, :string, default: "upload_bridge"
  attr :dom_id, :string, default: "video-upload-bridge"

  attr :font, :string,
    default:
      "var(--font-sans, Inter, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif)"

  def video_upload_panel(assigns) do
    ~H"""
    <div class="w-full bg-stone-900 overflow-hidden">
      <div class="w-full aspect-video bg-stone-900 flex items-center justify-center">
        <div
          id={@dom_id}
          class="w-full h-full"
          phx-hook={if @hook in [nil, ""], do: nil, else: @hook}
        >
          <mave-upload
            class="dashboard-upload block w-full h-full"
            token={@token}
            font={@font}
            disableCompletion
          >
            <div
              slot="initial"
              class="dashboard-upload-initial relative w-full h-full overflow-hidden bg-stone-900"
            >
              <div class="dashboard-upload-default absolute inset-0 flex flex-col items-center justify-center transition duration-150 ease-out">
                <div class="w-24 h-24 mb-4 text-blue-500 p-4">
                  <.animated_icon
                    name="upload"
                    class="w-full h-full"
                    speed="1"
                  />
                </div>
                <div class="text-white text-3xl mb-5 font-medium select-none cursor-default">
                  {gettext("drop video here")}
                </div>
                <div class="flex items-center text-stone-400">
                  <div class="h-full text-md mb-0.5 border-b border-transparent select-none cursor-default">
                    {gettext("or browse your files")}
                  </div>
                </div>
                <button
                  type="button"
                  data-mave-upload-select
                  class="relative mt-12 rounded-full bg-black px-6 py-2 text-md font-medium text-white ring-2 ring-inset ring-transparent transition duration-150 ease-out hover:scale-105 hover:ring-blue-600 active:bg-blue-600 cursor-pointer"
                >
                  <span class="pb-0.5">{gettext("select file")}</span>
                </button>
              </div>

              <div class="dashboard-upload-dragover absolute inset-0 flex flex-col items-center justify-center opacity-0 pointer-events-none transition duration-150 ease-out">
                <div class="dashboard-upload-dragover-frame absolute inset-0 ring ring-inset ring-blue-500">
                </div>
                <div class="relative z-10 text-green-500 p-4">
                  <div class="my-2 w-28 h-16">
                    <.animated_icon
                      name="checked"
                      class="w-full h-full"
                      speed="1"
                    />
                  </div>
                </div>
                <div class="relative z-10 text-white text-3xl mb-5 font-medium select-none">
                  {gettext("you can let go")}
                </div>
                <div class="relative z-10 flex items-center text-stone-400">
                  <div class="h-full text-md mb-0.5 border-b border-transparent select-none">
                    {gettext("we are ready")}
                  </div>
                </div>
              </div>
            </div>

            <div slot="uploading" class="w-full h-full overflow-hidden relative bg-stone-900">
              <div class="absolute inset-0 flex flex-col">
                <div class="flex-grow"></div>
                <div class="flex-none h-40 overflow-hidden saturate-200">
                  <.animated_icon
                    name="waves"
                    class="w-full h-64 rotate-180"
                    speed="2"
                    loop
                  />
                </div>
              </div>
              <div class="absolute inset-0 flex flex-col items-center justify-center">
                <div class="text-white text-3xl mb-8 font-medium select-none">
                  {gettext("uploading")}
                </div>
                <div class="text-stone-400 text-md mb-4 select-none text-opacity-60 pl-0.5">
                  <span data-role="progress-value">0%</span>
                </div>
                <div class="w-72 h-1 overflow-hidden rounded-full bg-stone-800">
                  <div
                    data-role="progress-bar"
                    class="h-1 rounded-full bg-blue-500 transition-all duration-300"
                    style="width: 0%;"
                  >
                  </div>
                </div>
              </div>
            </div>

            <div
              slot="processing"
              class="w-full h-full flex flex-col items-center justify-center bg-stone-900"
            >
              <div class="text-red-500 p-4">
                <div class="my-2 w-24 h-24">
                  <.animated_icon
                    name="processing"
                    class="w-full h-full"
                    speed="1.5"
                    loop
                  />
                </div>
              </div>
              <div class="text-white text-3xl mb-5 font-medium select-none">
                {gettext("processing...")}
              </div>
              <div class="flex items-center text-stone-400">
                <div class="h-full text-md mb-0.5 border-b border-transparent select-none">
                  {gettext("this may take a few minutes")}
                </div>
              </div>
            </div>

            <div
              slot="done"
              class="w-full h-full flex flex-col items-center justify-center bg-stone-900"
            >
              <div class="text-red-500 p-4">
                <div class="my-2 w-24 h-24">
                  <.animated_icon
                    name="processing"
                    class="w-full h-full"
                    speed="1.5"
                    loop
                  />
                </div>
              </div>
              <div class="text-white text-3xl mb-5 font-medium select-none">
                {gettext("processing...")}
              </div>
              <div class="flex items-center text-stone-400">
                <div class="h-full text-md mb-0.5 border-b border-transparent select-none">
                  {gettext("preparing your video")}
                </div>
              </div>
            </div>

            <div
              slot="error"
              class="w-full h-full flex flex-col items-center justify-center bg-stone-900"
            >
              <div class="text-red-500 p-4">
                <div class="my-2 w-28 h-16">
                  <.animated_icon
                    name="cross"
                    class="w-full h-full"
                    speed="1"
                  />
                </div>
              </div>
              <div
                data-role="error-title"
                class="text-white text-3xl mb-5 font-medium select-none"
              >
                {gettext("oops")}
              </div>
              <div class="flex items-center text-stone-400 px-6 text-center">
                <div
                  data-role="error-message"
                  class="h-full text-md mb-0.5 border-b border-transparent select-none"
                >
                  {gettext("something went wrong")}
                </div>
              </div>
              <div
                data-role="error-filename"
                class="text-stone-400 text-sm mt-3 min-h-6 max-w-sm text-center break-all"
              >
              </div>
              <button
                type="button"
                data-mave-upload-select
                class="relative mt-8 rounded-full bg-black px-6 py-2 text-md font-medium text-white ring-2 ring-inset ring-transparent transition duration-150 ease-out hover:scale-105 hover:ring-blue-600 active:bg-blue-600 cursor-pointer"
              >
                <span class="pb-0.5">{gettext("retry")}</span>
              </button>
            </div>
          </mave-upload>
        </div>
      </div>
    </div>
    """
  end

  attr :audio_only, :boolean, default: false

  def video_processing_panel(assigns) do
    ~H"""
    <div class={[
      "w-full bg-stone-900 flex flex-col items-center justify-center",
      if(@audio_only, do: "py-6", else: "aspect-video")
    ]}>
      <div class="text-red-500 p-4">
        <div class="my-2 w-24 h-24">
          <.animated_icon
            name="processing"
            class="w-full h-full"
            speed="1.5"
            loop
          />
        </div>
      </div>
      <div class="text-white text-3xl mb-5 font-medium select-none">
        {gettext("processing...")}
      </div>
      <div class="flex items-center text-stone-400">
        <div class="h-full text-md mb-0.5 border-b border-transparent select-none">
          {gettext("this may take a few minutes")}
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :loading, :boolean, default: false

  def video_metric_card(assigns) do
    ~H"""
    <div
      class="rounded-lg overflow-hidden shadow-sm shadow-stone-100 ring-1 ring-stone-200/50"
      aria-busy={to_string(@loading)}
    >
      <.section_title label={@label} />
      <div class="text-sm text-stone-400 pt-6 px-6">views</div>
      <div class="text-5xl font-extralight text-stone-500 pt-3 pb-6 px-6">
        <div
          :if={@loading}
          class="data-loading-skeleton h-12 w-24 rounded-md"
          aria-hidden="true"
        >
        </div>
        <span :if={@loading} class="sr-only">{gettext("Loading")}</span>
        <span :if={!@loading}>{@value}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, default: nil
  slot :inner_block, required: true

  def video_data_section(assigns) do
    ~H"""
    <div class="rounded-lg overflow-hidden shadow-sm shadow-stone-100 ring-1 ring-stone-200/50">
      <.section_title :if={@label} label={@label} />
      {render_slot(@inner_block)}
    </div>
    """
  end
end
