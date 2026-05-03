defmodule TodoWeb.Layouts do
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
        <title>Todo</title>
        <style>
          *, *::before, *::after { box-sizing: border-box; }

          body {
            font-family: system-ui, -apple-system, sans-serif;
            background: #f5f5f5;
            margin: 0;
            padding: 2rem 1rem;
            color: #222;
          }

          .todoapp {
            max-width: 520px;
            margin: 0 auto;
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 10px;
            padding: 1.5rem;
          }

          .header h1 {
            font-size: 1.4rem;
            font-weight: 700;
            margin: 0 0 1rem;
          }

          .new-todo {
            width: 100%;
            padding: 0.6rem 0.85rem;
            font-family: inherit;
            font-size: 0.95rem;
            border: 1px solid #e0e0e0;
            border-radius: 6px;
            background: #fafafa;
            color: #222;
            outline: none;
          }

          .new-todo::placeholder { color: #aaa; }

          .new-todo:focus {
            border-color: #aaa;
            background: white;
          }

          .main { margin-top: 1.25rem; }

          .toggle-all {
            width: 16px;
            height: 16px;
            margin-right: 0.6rem;
            cursor: pointer;
            vertical-align: middle;
          }

          .todo-list {
            list-style: none;
            padding: 0;
            margin: 0.5rem 0 0;
            border-top: 1px solid #f0f0f0;
          }

          .todo-list li {
            display: flex;
            align-items: center;
            padding: 0.6rem 0;
            border-bottom: 1px solid #f0f0f0;
          }

          .todo-list li:hover .destroy { opacity: 1; }

          .view {
            display: flex;
            align-items: center;
            width: 100%;
            gap: 0.6rem;
          }

          .todo-list input[type="checkbox"] {
            width: 16px;
            height: 16px;
            flex-shrink: 0;
            cursor: pointer;
          }

          .todo-list label {
            flex: 1;
            font-size: 0.95rem;
            color: #222;
            cursor: pointer;
          }

          .todo-list li.completed label {
            text-decoration: line-through;
            color: #aaa;
          }

          .destroy {
            opacity: 0;
            border: none;
            background: none;
            cursor: pointer;
            color: #ccc;
            font-size: 1.1rem;
            line-height: 1;
            padding: 2px 4px;
            flex-shrink: 0;
          }

          .destroy:hover { color: #888; }

          .footer {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-top: 1rem;
            padding-top: 0.75rem;
            border-top: 1px solid #f0f0f0;
          }

          .todo-count {
            font-size: 0.8rem;
            color: #888;
          }

          .todo-count strong { color: #444; font-weight: 600; }

          .filters {
            display: flex;
            gap: 4px;
            list-style: none;
            padding: 0;
            margin: 0;
          }

          .filters a {
            font-size: 0.8rem;
            color: #888;
            text-decoration: none;
            padding: 3px 10px;
            border: 1px solid transparent;
            border-radius: 4px;
          }

          .filters a:hover { border-color: #ddd; color: #444; }

          .filters a.selected {
            border-color: #ccc;
            color: #222;
            font-weight: 600;
          }
        </style>
      </head>
      <body>
        <%= @inner_content %>
        <script src="/phoenix/phoenix.min.js"></script>
        <script src="/phoenix_live_view/phoenix_live_view.min.js"></script>
        <script>
          let Hooks = {};
          Hooks.AutoFocus = {
            mounted() { this.el.focus() },
            updated() {
              if (this.el.dataset.clearKey !== this._clearKey) {
                this._clearKey = this.el.dataset.clearKey;
                this.el.value = "";
                this.el.focus();
              }
            }
          };

          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrfToken},
            hooks: Hooks
          });
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
