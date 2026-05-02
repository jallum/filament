defmodule CartWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Cart</title>
        <style>
          body { font-family: sans-serif; max-width: 700px; margin: 2rem auto; }
          .cart-badge { background: #e53e3e; color: white; border-radius: 999px;
                        padding: 2px 8px; font-size: 0.8em; margin-left: 8px; }
          .cart-badge:empty { display: none; }
          .cart-view ul { list-style: none; padding: 0; }
          .cart-view li { display: flex; align-items: center; gap: 8px; padding: 6px 0;
                          border-bottom: 1px solid #eee; }
          .cart-view .remove { border: none; background: none; cursor: pointer; color: red; }
          .cart-view .total { font-weight: bold; margin-top: 1rem; }
          .products { margin-bottom: 2rem; }
          .products button { margin: 4px; padding: 6px 12px; cursor: pointer; }
          h1 { display: flex; align-items: center; }
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
