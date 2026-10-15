defmodule InventoryWeb.Layouts do
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
        <title>Inventory</title>
        <style>
          *, *::before, *::after { box-sizing: border-box; }

          body {
            font-family: system-ui, -apple-system, sans-serif;
            background: #f5f5f5;
            margin: 0;
            padding: 2rem 1rem;
            color: #222;
          }

          .inventory-page {
            max-width: 480px;
            margin: 0 auto;
          }

          .inventory-page h1 {
            font-size: 1.4rem;
            font-weight: 700;
            margin: 0 0 0.25rem;
          }

          .inventory-page > p {
            font-size: 0.85rem;
            color: #666;
            margin: 0 0 1.5rem;
          }

          .items {
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
          }

          .inventory-item {
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            padding: 1rem 1.25rem;
            display: flex;
            align-items: center;
            gap: 0.75rem;
          }

          .inventory-item strong {
            flex: 1;
            font-size: 1rem;
          }

          .inventory-item .available {
            font-size: 0.85rem;
            color: #555;
          }

          .inventory-item .held {
            font-size: 0.85rem;
            font-weight: 600;
            color: #1a6fdb;
            background: #e8f0fb;
            padding: 2px 8px;
            border-radius: 12px;
          }

          .inventory-item .status.out-of-stock {
            font-size: 0.8rem;
            color: #999;
          }

          .inventory-item button {
            width: 28px;
            height: 28px;
            border: 1px solid #ccc;
            border-radius: 6px;
            background: white;
            cursor: pointer;
            font-size: 1rem;
            line-height: 1;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 0;
            flex-shrink: 0;
          }

          .inventory-item button:hover {
            background: #f0f0f0;
            border-color: #aaa;
          }

          .tip {
            max-width: 480px;
            margin: 0 auto 1rem;
            font-size: 0.8rem;
            color: #888;
            text-align: center;
          }
        </style>
      </head>
      <body>
        <p class="tip">Try opening this page in another tab — inventory adjustments in one tab update live in all others. Closing a tab should automatically release the inventory that it had reserved.</p>
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
