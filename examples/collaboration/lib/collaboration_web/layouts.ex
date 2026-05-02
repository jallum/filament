defmodule CollaborationWeb.Layouts do
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
          body { font-family: sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }
          .document-editor { border: 1px solid #ddd; border-radius: 8px; padding: 1.5rem; margin: 1rem 0; }
          .presence { color: #666; font-size: 0.9em; margin-bottom: 0.5rem; }
          .lock-status { display: flex; align-items: center; gap: 1rem; }
          .locked { color: #c0392b; font-weight: bold; }
          .unlocked { color: #27ae60; font-weight: bold; }
          .edit-btn { padding: 0.4rem 1rem; background: #3498db; color: white; border: none; border-radius: 4px; cursor: pointer; }
          .edit-btn:hover { background: #2980b9; }
          .view-only-btn { padding: 0.4rem 1rem; background: #bdc3c7; color: #7f8c8d; border: none; border-radius: 4px; cursor: not-allowed; }
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
