defmodule Filament.Cell do
  @moduledoc """
  Reactive value with subscribers and a projection-equality check.

  A cell is the unit of reactivity in Filament. Components consume cells via
  hooks (`use_observable`, `use_cell`); transports — GenServer-backed
  observables, in-process structs, focus trackers — provide them. The
  component is unaware of the transport; swapping transports is purely a
  wrapper concern.

  ## Shape

  A cell value is a tagged tuple:

      cell :: {transport_module :: module(), transport_data :: term()}

  The dispatch helpers in this module route subscribe / unsubscribe / current
  calls to `transport_module`. Each transport implements the callbacks below
  with whatever mechanism it likes (a GenServer call, a synchronous Agent
  read, a direct ETS lookup, etc.).

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
  @type t :: {transport(), transport_data()}
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
  Subscribe `subscriber` to `cell` with a projection. See the callback
  semantics above.
  """
  @spec subscribe(t(), subscriber(), projection()) :: {:ok, projected()} | :disconnected
  def subscribe({transport, data}, subscriber, projection) when is_function(projection, 1) do
    transport.subscribe(data, subscriber, projection)
  end

  @doc "Cancel a subscription. Idempotent."
  @spec unsubscribe(t(), subscriber()) :: :ok
  def unsubscribe({transport, data}, subscriber) do
    transport.unsubscribe(data, subscriber)
  end

  @doc "Read the current projected value without subscribing."
  @spec current(t(), projection()) :: projected() | :disconnected
  def current({transport, data}, projection) when is_function(projection, 1) do
    transport.current(data, projection)
  end
end
