defmodule Filament do
  @moduledoc """
  Filament — a process-aware UI framework for Phoenix LiveView.

  Filament brings React-style component composition and hooks to LiveView,
  with first-class support for observable domain state.

  ## Core concepts

  **Components** are defined with `defcomponent`, declare typed `prop` attributes,
  and render HTML with the `~F` sigil (HEEx templates).

      defcomponent MyApp.Greeting do
        prop :name, :string, required: true

        def render(assigns) do
          ~F\"""
          <h1>Hello, {@name}!</h1>
          \"""
        end
      end

  **Hooks** run inside `render/1` and give components access to mutable state
  and external services:

    - `use_state/1` — local component state (re-renders on change)
    - `use_observable/1` — resolve a server reference to a pid (nil when disconnected)
    - `use_observable/2` — subscribe to an observable and return the projected value
    - `use_effect/2` — side-effect with cleanup (run after render)
    - `use_event_ref/1` — stable wire ref for JS hooks to route `pushEvent` to this fiber

  **LiveView adapter** — use a Filament component tree as a LiveView:

      defmodule MyApp.MyLive do
        use Filament.LiveView
        def root_component, do: MyApp.RootComponent
      end

  ## Interop with existing LiveViews

  To embed a Filament component inside an existing Phoenix LiveView, use
  `Filament.LiveComponent`:

      <.live_component module={Filament.LiveComponent} id="cart" component={CartView} />

  See `Filament.LiveComponent` for the observable-forwarding requirement.

  ## Guides

  - "Getting Started" — first component, props, state, events, testing
  - "Observables" — Observable.GenServer, projections, change-or-bust
  - "Migration Guide" — converting LiveView assigns to Filament observables
  """
end
