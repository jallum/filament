defmodule Filament.Cell do
  @moduledoc """
  Behaviour that a Filament transport implements.

  A *cell* is the unit of reactivity in Filament. Components consume cells
  via hooks (`use_source` to bind, `use_value` to read); transports —
  GenServer-backed observables, in-process structs, focus trackers — provide
  them by implementing this behaviour. Components are unaware of which
  transport delivers a cell's value.

  ## Vocabulary

  Filament splits the API surface into two related names:

    * **`Filament.Cell`** — this module. The *behaviour* a transport author
      implements. Defines `subscribe/3`, `unsubscribe/2`, `current/2`
      callbacks and routing helpers that dispatch through to the transport.

    * **`Filament.Source`** — the *struct* application code holds. Carries
      the transport module + transport-specific data. Returned by
      `use_source/1` and passed to `use_value/2`.

  ## Shape

  A source is a struct:

      %Filament.Source{transport: module(), data: term()}

  The dispatch helpers in this module route subscribe / unsubscribe / current
  calls through `source.transport`. Each transport implements the callbacks
  below however it likes (a GenServer call, a synchronous Agent read, a
  direct ETS lookup, etc.).

  ## Change-or-bust

  The transport runs the subscriber's projection function on each new value
  and notifies the subscriber only when the projected value differs from the
  previously delivered one. Cells therefore deliver only meaningful updates,
  not raw write traffic.

  ## Subscriber identity

  `subscriber` is opaque to `Filament.Cell` — typically the tuple
  `{owner_pid, fiber_id, slot_index}` Filament's hooks layer uses, but a
  transport may accept any term. Two subscribes with the same identity
  replace the previous projection.
  """

  @type transport :: module()
  @type transport_data :: term()
  @type t :: Filament.Source.t()
  @type subscriber :: term()
  @type projection :: (term() -> term())
  @type projected :: term()

  @doc """
  Subscribe to a cell. Returns `{:ok, projected_value}` with the current
  projected value, or `:disconnected` if the transport can't reach the
  underlying value (e.g. the GenServer process isn't started yet).
  """
  @callback subscribe(transport_data(), subscriber(), projection()) ::
              {:ok, projected()} | :disconnected

  @doc """
  Cancel a subscription. Idempotent — must not error on unknown subscribers.
  """
  @callback unsubscribe(transport_data(), subscriber()) :: :ok

  @doc """
  Read the current projected value without subscribing.
  """
  @callback current(transport_data(), projection()) :: projected() | :disconnected

  @doc """
  Subscribe `subscriber` to `source` with a projection. See the callback
  semantics above.
  """
  @spec subscribe(t(), subscriber(), projection()) :: {:ok, projected()} | :disconnected
  def subscribe(%Filament.Source{transport: t, data: d}, subscriber, projection) when is_function(projection, 1) do
    t.subscribe(d, subscriber, projection)
  end

  @doc "Cancel a subscription. Idempotent."
  @spec unsubscribe(t(), subscriber()) :: :ok
  def unsubscribe(%Filament.Source{transport: t, data: d}, subscriber) do
    t.unsubscribe(d, subscriber)
  end

  @doc "Read the current projected value without subscribing."
  @spec current(t(), projection()) :: projected() | :disconnected
  def current(%Filament.Source{transport: t, data: d}, projection) when is_function(projection, 1) do
    t.current(d, projection)
  end

  @doc """
  Optional reachability check used by `use_source/1` to decide whether a
  cached source's underlying transport is still alive. Transports may
  override `reachable?/1`; the default returns `true`.
  """
  @spec reachable?(t()) :: boolean()
  def reachable?(%Filament.Source{transport: t, data: d}) do
    if function_exported?(t, :reachable?, 1), do: t.reachable?(d), else: true
  end
end
