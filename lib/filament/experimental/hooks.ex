defmodule Filament.Experimental.Hooks do
  @moduledoc """
  Experimental hooks that are not yet part of the stable Filament API.

  Import this module inside `render/1` (or at the top of your component) to opt in:

      import Filament.Experimental.Hooks

  Experimental hooks may change or be removed in future releases.
  """

  @doc """
  Registers an event handler and returns a stable wire ref for use as a `data-ref`
  attribute. JS hooks send events to this fiber via `this.pushEvent(ref, payload)`;
  Filament dispatches directly to the handler closure.

  The ref string (e.g. `"filament:root.MyComponent[0]:0"`) is stable across re-renders
  as long as `use_event_ref/1` is called in the same order each render.

  ## Handler arities

  **1-arity** — receives the payload map:

      submit_ref = use_event_ref(fn %{"text" => t} -> process(t) end)

  **2-arity** — receives the payload map and a `push` function for sending events back
  to the specific JS hook instance that called in:

      accept_ref = use_event_ref(fn %{"value" => v}, push ->
        result = process(v)
        push.("picker_accept", %{value: result})
      end)

  Pushes are automatically scoped to the wire ref, so two instances of the same
  hook on the page each only receive their own component's push.

  ## JS side

  Pass the ref via `data-ref` and use `filament.handleEvent` to receive scoped pushes:

      ~F\"""
      <div phx-hook="MyHook" data-ref={accept_ref} />
      \"""

      // JS hook
      mounted() {
        filament.handleEvent(this, "picker_accept", ({ value }) => { ... })
      }

  `filament.handleEvent` is a thin wrapper around `this.handleEvent` that prefixes
  the event name with the component's wire ref, matching what the server pushes.

  Rules: call only at the top level of `render/1`. Do not call inside conditionals.
  """
  @spec use_event_ref(handler :: function()) :: wire_ref :: String.t()
  def use_event_ref(handler) when is_function(handler) do
    "filament:" <> Filament.Hooks.register_event_handler(handler)
  end
end
