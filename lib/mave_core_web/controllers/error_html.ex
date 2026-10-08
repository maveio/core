defmodule MaveCoreWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use MaveCoreWeb, :html

  embed_templates "error_html/*"

  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :note, :string, required: true

  def error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>{@title}</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
        </script>
      </head>
      <body
        class="h-full bg-stone-100 antialiased"
        style="font-family: var(--font-sans); color-scheme: light;"
      >
        <main class="flex min-h-full items-center justify-center px-6 py-16 text-stone-700">
          <div class="w-full max-w-md text-center">
            <img src="/images/glyph.svg" alt="" class="mx-auto h-9 w-9 opacity-20" />

            <h1 class="mt-10 text-3xl font-light leading-tight text-stone-800">
              {@title}
            </h1>
            <p class="mt-4 text-sm leading-6 text-stone-500">
              {@message}
            </p>
            <p class="mt-6 border-t border-stone-200 pt-6 text-xs leading-5 text-stone-400">
              {@note}
            </p>

            <div class="mt-8 flex items-center justify-center text-sm">
              <.link href={~p"/"} class="font-medium text-blue-500 hover:text-blue-600">
                Go to dashboard
              </.link>
            </div>
          </div>
        </main>
      </body>
    </html>
    """
  end

  def render("404.html", assigns), do: apply(__MODULE__, :"404", [assigns])
  def render("500.html", assigns), do: apply(__MODULE__, :"500", [assigns])
  def render("400.html", assigns), do: apply(__MODULE__, :"400", [assigns])

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
