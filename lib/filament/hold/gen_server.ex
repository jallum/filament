defmodule Filament.Hold.GenServer do
  @moduledoc """
  Macro that makes a GenServer capable of granting resource holds to Filament components.

  `use Filament.Hold.GenServer` injects:

    - `handle_call({:filament_acquire, request, holder}, from, state)` —
      hold acquisition; calls `handle_acquire/3` (overridable)
    - `handle_cast({:filament_release, holder}, state)` —
      explicit hold release; calls `handle_release/3` (overridable)
    - `handle_info({:DOWN, ref, :process, pid, reason}, state)` —
      automatic hold release when the holder LiveView process terminates

  > #### Do not mix with Observable.GenServer {: .warning}
  >
  > Do **not** use both `use Filament.Hold.GenServer` and
  > `use Filament.Observable.GenServer` in the same module. Both inject
  > `handle_info/2` for `{:DOWN, ref, :process, ...}` and the compiler will
  > raise a duplicate clause error. If you need both capabilities in one server
  > (e.g., a server that both notifies subscribers and manages holds), use only
  > `Filament.Observable.GenServer` and implement lock/hold management manually
  > in the server state.

  ## Example

      defmodule MyApp.InventoryServer do
        use Filament.Hold.GenServer

        def start_link(opts \\\\ []) do
          GenServer.start_link(__MODULE__, %{items: %{}}, name: __MODULE__)
        end

        @impl GenServer
        def init(state), do: {:ok, state}

        @impl Filament.Hold
        def handle_acquire({:reserve, item_id}, holder, state) do
          case reserve_item(state, item_id, holder) do
            {:ok, token, new_state} -> {:ok, token, new_state}
            {:error, :unavailable, _} -> {:error, :unavailable, state}
          end
        end

        @impl Filament.Hold
        def handle_release(token, _holder, state) do
          {:ok, release_item(state, token)}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Filament.Hold

      # ── Default callbacks (overridable) ────────────────────────────────────

      @impl Filament.Hold
      def handle_acquire(_request, _holder, state), do: {:ok, make_ref(), state}

      @impl Filament.Hold
      def handle_release(_token, _holder, state), do: {:ok, state}

      defoverridable handle_acquire: 3, handle_release: 3

      # ── Injected GenServer message handlers ──────────────────────────────

      @impl true
      def handle_call({:filament_acquire, request, holder}, _from, state) do
        case apply(__MODULE__, :handle_acquire, [request, holder, state]) do
          {:ok, token, new_state} ->
            ref = Process.monitor(holder)
            holds = Process.get(:__filament_holds__, %{})
            Process.put(:__filament_holds__, Map.put(holds, holder, {ref, token}))
            {:reply, {:ok, token}, new_state}

          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end
      end

      @impl true
      def handle_cast({:filament_release, holder}, state) do
        holds = Process.get(:__filament_holds__, %{})

        case Map.pop(holds, holder) do
          {nil, _holds} ->
            {:noreply, state}

          {{ref, token}, new_holds} ->
            Process.demonitor(ref, [:flush])
            Process.put(:__filament_holds__, new_holds)
            {:ok, new_state} = apply(__MODULE__, :handle_release, [token, holder, state])
            {:noreply, new_state}
        end
      end

      @impl true
      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        holds = Process.get(:__filament_holds__, %{})

        case Enum.find(holds, fn {_pid, {r, _token}} -> r == ref end) do
          nil ->
            {:noreply, state}

          {holder, {_ref, token}} ->
            new_holds = Map.delete(holds, holder)
            Process.put(:__filament_holds__, new_holds)
            {:ok, new_state} = apply(__MODULE__, :handle_release, [token, holder, state])
            {:noreply, new_state}
        end
      end
    end
  end
end
