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
  `{owner_pid, fiber_id, slot_index, generation}` Filament's hooks layer uses, but a
  transport may accept any term. Subscribing again with the same identity
  refreshes the subscription: it takes the new projection and replies with
  the current value, while the transport keeps the subscription itself.

  Filament unsubscribes when a component unmounts, but not when its owner
  process exits. A transport that keeps per-subscriber state must monitor
  the owner (the first element of the hooks layer's tuple) and drop its
  subscriptions on exit, as `Filament.Observable.GenServer` does.
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
  The process holding the cell's state, or `nil` when it isn't running.

  `use_value/2` monitors this process and subscribes again when it exits, so
  a restarted server reaches its readers; `use_source/1` calls a factory again
  when it returns `nil`. Without this callback a source is always reachable and
  its readers learn of a restart only by rendering.
  """
  @callback whereis(transport_data()) :: pid() | {atom(), node()} | nil

  @optional_callbacks whereis: 1

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
  The process holding `source`'s state, `nil` when it isn't running, or
  `:unknown` when the transport doesn't implement `c:whereis/1`.
  """
  @spec whereis(t()) :: pid() | {atom(), node()} | nil | :unknown
  def whereis(%Filament.Source{transport: t, data: d}) do
    # function_exported?/3 is false until the module is loaded.
    if Code.ensure_loaded?(t) and function_exported?(t, :whereis, 1), do: t.whereis(d), else: :unknown
  end
end
