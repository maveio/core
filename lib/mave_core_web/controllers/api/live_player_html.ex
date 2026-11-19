defmodule MaveCoreWeb.Api.LivePlayerHTML do
  @moduledoc false
  use MaveCoreWeb, :html

  def page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex" />
        <title>{@name || gettext("Live stream")}</title>
        <style nonce={@nonce}>
          html, body { height: 100%; margin: 0; background: #0c0a09; }
          #live-player { position: relative; width: 100%; height: 100%; font: 500 14px/1.4 system-ui, sans-serif; color: #e7e5e4; }
          #live-player video { width: 100%; height: 100%; object-fit: contain; background: #0c0a09; display: block; }
          #live-player [data-notice] { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; padding: 24px; text-align: center; color: #a8a29e; }
          #live-player [data-badge] { position: absolute; top: 12px; left: 12px; display: flex; align-items: center; gap: 6px; padding: 3px 9px 3px 8px; border-radius: 4px; background: #dc2626; color: #fff; font-size: 12px; font-weight: 600; letter-spacing: 0.06em; }
          #live-player [data-badge]::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: #fff; }
          #live-player [hidden] { display: none !important; }
        </style>
      </head>
      <body>
        <div
          id="live-player"
          data-status-url={@status_url}
          data-src={@src}
          data-offline={gettext("This stream is offline.")}
          data-ended={gettext("This stream has ended.")}
          data-unavailable={gettext("This stream is not available.")}
        >
          <video controls playsinline hidden></video>
          <div data-notice hidden></div>
          <div data-badge hidden>{gettext("LIVE")}</div>
        </div>
        <script src={@script} defer>
        </script>
      </body>
    </html>
    """
  end
end
