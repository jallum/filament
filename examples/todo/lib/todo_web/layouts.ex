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
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Newsreader:ital,opsz,wght@0,6..72,300;0,6..72,400;0,6..72,500;0,6..72,600;1,6..72,400;1,6..72,500&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
        <style>
          :root {
            --paper: #f4ede0;
            --paper-warm: #ece4d3;
            --ink: #1a1410;
            --ink-soft: #3a2f26;
            --muted: #7a6957;
            --rule: #d8cebb;
            --flame: #c9472b;
            --flame-deep: #8a2a14;
          }

          * { margin: 0; padding: 0; box-sizing: border-box; }

          body {
            background: var(--paper);
            color: var(--ink);
            font-family: 'Newsreader', Georgia, serif;
            font-weight: 400;
            font-size: 18px;
            line-height: 1.6;
            -webkit-font-smoothing: antialiased;
            min-height: 100vh;
          }

          ::selection { background: var(--flame); color: var(--paper); }

          .container {
            max-width: 720px;
            margin: 0 auto;
            padding: 0 32px;
          }

          /* App header */
          .app-header {
            padding: 64px 0 48px;
            border-bottom: 1px solid var(--rule);
            margin-bottom: 48px;
          }

          .app-mark {
            width: 32px;
            height: 32px;
            margin-bottom: 24px;
          }

          .app-mark line { stroke: var(--ink); stroke-width: 1.5; }
          .app-mark line.accent { stroke: var(--flame); }

          .app-title {
            font-family: 'Instrument Serif', serif;
            font-style: italic;
            font-size: 56px;
            line-height: 1;
            letter-spacing: -0.02em;
            color: var(--ink);
          }

          .app-title .dot { color: var(--flame); font-style: normal; }

          .app-tagline {
            font-family: 'Newsreader', serif;
            font-size: 18px;
            font-style: italic;
            color: var(--ink-soft);
            margin-top: 12px;
          }

          /* Todo list section */
          .todoapp {
            margin-bottom: 64px;
          }

          .header {
            margin-bottom: 32px;
          }

          .header h1 {
            font-family: 'Instrument Serif', serif;
            font-weight: 400;
            font-size: 36px;
            color: var(--ink);
            margin-bottom: 16px;
          }

          /* Input form */
          .new-todo {
            width: 100%;
            padding: 16px 20px;
            font-family: 'Newsreader', serif;
            font-size: 18px;
            border: 1px solid var(--rule);
            border-radius: 4px;
            background: var(--paper-warm);
            color: var(--ink);
            outline: none;
            transition: border-color 0.15s, box-shadow 0.15s;
          }

          .new-todo::placeholder {
            color: var(--muted);
            font-style: italic;
          }

          .new-todo:focus {
            border-color: var(--flame);
            box-shadow: 0 0 0 3px rgba(201, 71, 43, 0.1);
          }

          /* Main section */
          .main {
            margin-top: 32px;
          }

          .toggle-all {
            width: 20px;
            height: 20px;
            margin-right: 16px;
            accent-color: var(--flame);
            cursor: pointer;
          }

          /* Todo list */
          .todo-list {
            list-style: none;
            border-top: 1px solid var(--rule);
          }

          .todo-list li {
            display: flex;
            align-items: center;
            padding: 16px 0;
            border-bottom: 1px solid var(--rule);
          }

          .todo-list li:hover .destroy {
            opacity: 1;
          }

          .todo-list input[type="checkbox"] {
            width: 20px;
            height: 20px;
            margin-right: 16px;
            accent-color: var(--flame);
            cursor: pointer;
          }

          .todo-list label {
            flex: 1;
            font-size: 18px;
            color: var(--ink);
            cursor: pointer;
          }

          .todo-list li.completed label {
            text-decoration: line-through;
            color: var(--muted);
          }

          .destroy {
            opacity: 0;
            border: none;
            background: none;
            cursor: pointer;
            color: var(--muted);
            font-size: 24px;
            line-height: 1;
            padding: 4px 8px;
            transition: opacity 0.15s, color 0.15s;
          }

          .destroy:hover {
            color: var(--flame);
          }

          /* Footer */
          .footer {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-top: 24px;
            padding-top: 16px;
            border-top: 1px solid var(--rule);
          }

          .todo-count {
            font-family: 'JetBrains Mono', monospace;
            font-size: 12px;
            color: var(--muted);
          }

          .todo-count strong {
            color: var(--ink);
            font-weight: 500;
          }

          /* Filter bar */
          .filters {
            display: flex;
            gap: 8px;
            list-style: none;
          }

          .filters a {
            font-family: 'JetBrains Mono', monospace;
            font-size: 11px;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--muted);
            text-decoration: none;
            padding: 6px 12px;
            border: 1px solid transparent;
            border-radius: 3px;
            transition: all 0.15s;
          }

          .filters a:hover {
            color: var(--ink);
            border-color: var(--rule);
          }

          .filters a.selected {
            color: var(--flame);
            border-color: var(--flame);
          }

          /* App footer */
          .app-footer {
            padding: 48px 0;
            border-top: 1px solid var(--rule);
            margin-top: 64px;
            text-align: center;
          }

          .app-footer .colophon {
            font-family: 'JetBrains Mono', monospace;
            font-size: 10px;
            letter-spacing: 0.15em;
            text-transform: uppercase;
            color: var(--muted);
            line-height: 2;
          }

          .app-footer .sig {
            font-family: 'Instrument Serif', serif;
            font-style: italic;
            font-size: 24px;
            color: var(--flame);
            margin-top: 16px;
          }

          /* Responsive */
          @media (max-width: 768px) {
            .container { padding: 0 20px; }
            .app-header { padding: 40px 0 32px; }
            .app-title { font-size: 40px; }
          }
        </style>
      </head>
      <body>
        <div class="container">
          <header class="app-header">
            <svg class="app-mark" viewBox="0 0 32 32">
              <line x1="4" y1="4" x2="4" y2="28"/>
              <line x1="12" y1="4" x2="12" y2="28"/>
              <line class="accent" x1="20" y1="4" x2="20" y2="28"/>
              <line x1="28" y1="4" x2="28" y2="28"/>
            </svg>
            <h1 class="app-title">Filament<span class="dot">.</span></h1>
            <p class="app-tagline">A process-aware UI framework for the BEAM</p>
          </header>

          <%= @inner_content %>

          <footer class="app-footer">
            <div class="colophon">
              Built with Filament<br/>
              Phoenix LiveView &middot; BEAM &middot; Elixir
            </div>
            <div class="sig">Filament.</div>
          </footer>
        </div>
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
