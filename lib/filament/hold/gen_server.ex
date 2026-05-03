defmodule Filament.Hold.GenServer do
  @moduledoc """
  Macro that makes a GenServer capable of granting quantity-based resource holds
  to Filament components, with built-in observable support.

  `use Filament.Hold.GenServer` builds on `Filament.Observable.GenServer` and additionally
  injects:

    - `handle_call({:filament_hold, item_id, qty, holder_pid}, ...)` — hold acquisition;
      calls `handle_acquire/4` (overridable)
    - `handle_cast({:filament_release_qty, item_id, qty, holder_pid}, ...)` — explicit
      hold release; calls `handle_release/4` (overridable)
    - An override of `handle_unsubscribe/2` that releases all holds for the departing
      subscriber, so `:DOWN` cleanup is fully automatic.

  ## Example

      defmodule MyApp.InventoryServer do
        use Filament.Hold.GenServer

        def start_link(opts \\\\ []) do
          GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
        end

        @impl GenServer
        def init(items), do: {:ok, Map.new(items, &{&1.id, &1})}

        @impl Filament.Hold
        def handle_acquire(item_id, qty, _holder_pid, state) do
          case state[item_id] do
            %{available: a} when a >= qty ->
              {:ok, Map.update!(state, item_id, &%{&1 | available: &1.available - qty})}
            _ ->
              {:error, :insufficient, state}
          end
        end

        @impl Filament.Hold
        def handle_release(item_id, qty, _holder_pid, state) do
          {:ok, Map.update!(state, item_id, &%{&1 | available: &1.available + qty})}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use Filament.Observable.GenServer
      @behaviour Filament.Hold

      # ── Default hold callbacks (overridable) ──────────────────────────────

      @impl Filament.Hold
      def handle_acquire(_item_id, _qty, _holder_pid, state), do: {:ok, state}

      @impl Filament.Hold
      def handle_release(_item_id, _qty, _holder_pid, state), do: {:ok, state}

      defoverridable handle_acquire: 4, handle_release: 4

      # ── Override handle_unsubscribe to release all holds on disconnect ─────

      @impl Filament.Observable
      def handle_unsubscribe(subscriber, state) do
        holds = Process.get(:__filament_holds__, %{})

        case Map.pop(holds, subscriber.pid) do
          {nil, _holds} ->
            {:ok, state}

          {holder_holds, new_holds} ->
            Process.put(:__filament_holds__, new_holds)

            new_state =
              Enum.reduce(holder_holds, state, fn {item_id, qty}, acc ->
                {:ok, new_acc} = apply(__MODULE__, :handle_release, [item_id, qty, subscriber.pid, acc])
                new_acc
              end)

            notify_observers(new_state)
            {:ok, new_state}
        end
      end

      defoverridable handle_unsubscribe: 2

      # ── Injected hold/release GenServer message handlers ──────────────────

      @impl true
      def handle_call({:filament_hold, item_id, qty, holder_pid}, _from, state) do
        case apply(__MODULE__, :handle_acquire, [item_id, qty, holder_pid, state]) do
          {:ok, new_state} ->
            holds = Process.get(:__filament_holds__, %{})
            holder_holds = Map.get(holds, holder_pid, %{})
            new_holder_holds = Map.update(holder_holds, item_id, qty, &(&1 + qty))
            Process.put(:__filament_holds__, Map.put(holds, holder_pid, new_holder_holds))
            notify_observers(new_state)
            {:reply, :ok, new_state}

          {:error, reason, state} ->
            {:reply, {:error, reason}, state}
        end
      end

      @impl true
      def handle_cast({:filament_release_qty, item_id, qty, holder_pid}, state) do
        holds = Process.get(:__filament_holds__, %{})
        holder_holds = Map.get(holds, holder_pid, %{})
        current_qty = Map.get(holder_holds, item_id, 0)
        actual_qty = min(qty, current_qty)

        if actual_qty > 0 do
          new_holder_holds =
            if current_qty - actual_qty <= 0 do
              Map.delete(holder_holds, item_id)
            else
              Map.put(holder_holds, item_id, current_qty - actual_qty)
            end

          Process.put(:__filament_holds__, Map.put(holds, holder_pid, new_holder_holds))

          {:ok, new_state} =
            apply(__MODULE__, :handle_release, [item_id, actual_qty, holder_pid, state])

          notify_observers(new_state)
          {:noreply, new_state}
        else
          {:noreply, state}
        end
      end
    end
  end
end
