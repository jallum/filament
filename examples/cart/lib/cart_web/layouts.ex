defmodule CartWeb.Layouts do
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
        <title>Cart Demo</title>
        <style>
          *, *::before, *::after { box-sizing: border-box; }

          body {
            font-family: system-ui, -apple-system, sans-serif;
            background: #f5f5f5;
            margin: 0;
            padding: 2rem 1rem;
            color: #222;
          }

          .page {
            max-width: 640px;
            margin: 0 auto;
            display: flex;
            flex-direction: column;
            gap: 1.5rem;
          }

          .page-header {
            display: flex;
            align-items: center;
            gap: 0.75rem;
          }

          .page-header h1 {
            font-size: 1.25rem;
            font-weight: 600;
            margin: 0;
          }

          .cart-badge {
            background: #e53e3e;
            color: white;
            border-radius: 999px;
            padding: 2px 8px;
            font-size: 0.78rem;
            font-weight: 600;
            min-width: 22px;
            text-align: center;
          }

          .cart-badge:empty { display: none; }

          .products {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 1rem;
          }

          .product-card {
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 10px;
            padding: 1.25rem;
            display: flex;
            flex-direction: column;
            gap: 0.5rem;
          }

          .product-name {
            font-weight: 600;
            font-size: 0.95rem;
          }

          .product-price {
            color: #555;
            font-size: 0.85rem;
            flex: 1;
          }

          .btn-add {
            padding: 0.4rem 0.9rem;
            font-size: 0.85rem;
            font-family: inherit;
            background: #222;
            color: white;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            align-self: flex-start;
          }

          .btn-add:hover { background: #444; }

          .cart-section {
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 10px;
            overflow: hidden;
          }

          .cart-section h2 {
            font-size: 0.95rem;
            font-weight: 600;
            margin: 0;
            padding: 1rem 1.5rem;
            border-bottom: 1px solid #f0f0f0;
          }

          .cart-empty {
            color: #999;
            font-size: 0.875rem;
            padding: 1.5rem;
            margin: 0;
          }

          .cart-items {
            list-style: none;
            margin: 0;
            padding: 0;
          }

          .cart-item {
            display: flex;
            align-items: center;
            gap: 0.75rem;
            padding: 0.75rem 1.5rem;
            border-bottom: 1px solid #f5f5f5;
          }

          .item-name { flex: 1; font-size: 0.9rem; }
          .item-qty { color: #888; font-size: 0.85rem; }
          .item-price { font-size: 0.9rem; font-weight: 500; min-width: 4rem; text-align: right; }

          .btn-remove {
            padding: 0.25rem 0.6rem;
            font-size: 0.8rem;
            font-family: inherit;
            background: #fff0f0;
            color: #c0392b;
            border: 1px solid #f5c6c2;
            border-radius: 5px;
            cursor: pointer;
          }

          .btn-remove:hover { background: #fde8e8; }

          .cart-total {
            padding: 1rem 1.5rem;
            font-weight: 600;
            font-size: 0.95rem;
            text-align: right;
            border-top: 1px solid #f0f0f0;
          }

          .tip {
            max-width: 640px;
            margin: 0 auto 1rem;
            font-size: 0.8rem;
            color: #888;
            text-align: center;
          }
        </style>
      </head>
      <body>
        <p class="tip">Try opening this page in another tab — each tab gets its own independent cart, since cart state is isolated per session.</p>
        <%= @inner_content %>
        <script src="/phoenix/phoenix.min.js"></script>
        <script src="/phoenix_live_view/phoenix_live_view.min.js"></script>
        <Filament.LiveView.runtime_assets />
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
