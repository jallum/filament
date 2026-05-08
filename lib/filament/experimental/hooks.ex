defmodule Filament.Experimental.Hooks do
  @moduledoc """
  Experimental hooks that are not yet part of the stable Filament API.

  Import this module inside `render/1` (or at the top of your component) to opt in:

      import Filament.Experimental.Hooks

  Experimental hooks may change or be removed in future releases.
  """

  @doc """
  Registers an event handler and returns a stable wire ref suitable for use as a
  `data-*` attribute so JS hooks can route `pushEvent` calls directly to this fiber.

  The returned string (e.g. `"filament:root.MyComponent[0]:0"`) is stable across
  re-renders as long as `use_event_ref/1` is called in the same order each render.
  Pass it to a JS hook via a `data-*` attribute; the hook calls
  `this.pushEvent(ref, payload)` and Filament dispatches directly to the handler.

      import Filament.Experimental.Hooks

      def render(props) do
        submit_ref = use_event_ref(fn %{"text" => t} -> ... end)
        ~F\"""
        <textarea phx-hook="MyHook" data-ref={submit_ref} />
        \"""
      end

  Rules: call only at the top level of `render/1`. Do not call inside conditionals.
  """
  @spec use_event_ref(handler :: function()) :: wire_ref :: String.t()
  def use_event_ref(handler) when is_function(handler) do
    "filament:" <> Filament.Hooks.register_event_handler(handler)
  end
end
