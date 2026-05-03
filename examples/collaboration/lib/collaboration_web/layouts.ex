defmodule CollaborationWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Collaboration Demo</title>
        <style>
          *, *::before, *::after { box-sizing: border-box; }

          body {
            font-family: system-ui, -apple-system, sans-serif;
            background: #f5f5f5;
            margin: 0;
            padding: 2rem 1rem;
            color: #222;
          }

          .doc-editor {
            max-width: 600px;
            margin: 0 auto;
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 10px;
            overflow: hidden;
          }

          .doc-header {
            display: flex;
            align-items: baseline;
            justify-content: space-between;
            padding: 1.25rem 1.5rem;
            border-bottom: 1px solid #f0f0f0;
          }

          .doc-header h1 {
            font-size: 1rem;
            font-weight: 600;
            margin: 0;
          }

          .presence {
            font-size: 0.8rem;
            color: #999;
          }

          .doc-body {
            padding: 2rem 1.5rem;
            min-height: 200px;
          }

          .doc-placeholder {
            color: #ccc;
            font-style: italic;
            font-size: 0.9rem;
            text-align: center;
            margin-top: 4rem;
          }

          .connecting {
            color: #999;
            padding: 1.5rem;
            margin: 0;
          }

          .doc-footer {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            padding: 1rem 1.5rem;
            border-top: 1px solid #f0f0f0;
            background: #fafafa;
          }

          .lock-badge {
            font-size: 0.75rem;
            font-weight: 600;
            padding: 2px 8px;
            border-radius: 12px;
          }

          .lock-badge.locked {
            background: #fde8e8;
            color: #c0392b;
          }

          .lock-badge.unlocked {
            background: #e8f5e9;
            color: #27ae60;
          }

          .lock-holder {
            font-size: 0.8rem;
            color: #999;
            flex: 1;
          }

          .btn {
            padding: 0.4rem 1.1rem;
            font-size: 0.85rem;
            font-family: inherit;
            border: none;
            border-radius: 6px;
            cursor: pointer;
          }

          .btn-primary {
            background: #222;
            color: white;
          }

          .btn-primary:hover { background: #444; }

          .btn-release {
            background: #fff0f0;
            color: #c0392b;
            border: 1px solid #f5c6c2;
          }

          .btn-release:hover { background: #fde8e8; }

          .btn-disabled {
            background: #f0f0f0;
            color: #bbb;
            cursor: not-allowed;
          }
        </style>
      </head>
      <body>
        <%= @inner_content %>
        <script src="/phoenix/phoenix.min.js"></script>
        <script src="/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {params: {_csrf_token: csrfToken}});
          liveSocket.connect();
          window.liveSocket = liveSocket;
        </script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"<%= @inner_content %>"
  end
end
