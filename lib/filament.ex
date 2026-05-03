defmodule Filament do
  @moduledoc """
  Filament — a process-aware UI framework for Phoenix LiveView.

  Filament brings React-style component composition and hooks to LiveView,
  adding first-class support for observable domain state and resource holds.

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

    - `use_state/2` — local component state (re-renders on change)
    - `use_observable/3` — subscribe to an `Observable.GenServer` with an optional
      projection (only re-renders when the projected value changes)
    - `use_hold/3` — acquire a resource hold from a `Hold.GenServer`; released
      automatically if the LiveView process terminates
    - `use_memo/2` — memoised computation (recomputes only when deps change)
    - `use_effect/2` — side-effect with cleanup (run after render)

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
  - "Resource Holds" — Hold.GenServer, :DOWN lifecycle, out-of-stock UX
  - "Migration Guide" — converting LiveView assigns to Filament observables
  """
end
