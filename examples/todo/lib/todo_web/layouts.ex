defmodule TodoWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Todo</title>
        <style>
          body { font-family: sans-serif; max-width: 600px; margin: 2rem auto; }
          .todo-list { list-style: none; padding: 0; }
          .todo-list li { display: flex; align-items: center; gap: 8px; padding: 4px 0; }
          .completed label { text-decoration: line-through; color: #888; }
          .filters { display: flex; gap: 8px; margin-top: 1rem; }
          .filters .selected { font-weight: bold; }
          .destroy { border: none; background: none; cursor: pointer; color: red; }
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
