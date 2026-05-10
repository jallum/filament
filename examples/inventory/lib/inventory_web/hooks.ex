defmodule InventoryWeb.Hooks do
  @moduledoc """
  Custom hooks for the Inventory example — demonstrates how to build
  domain-specific hooks on top of `Filament.Hooks.use_source/1` and
  `Filament.Hooks.use_value/2`.
  """

  import Filament.Hooks

  @doc """
  Subscribe to an `Inventory.Server` and manage quantity-based holds for one item.

  Returns `{held_qty, item, hold, release}` on a live WebSocket connection:

  - `held_qty` — units this component currently holds
  - `item` — the current `%Inventory.Item{}` for `item_id`
  - `hold.(qty)` — acquire `qty` units; raises on denial
  - `release.(qty)` — release up to `qty` units

  Holds are released automatically when the LiveView disconnects (via
  `handle_unsubscribe/2` on the server).

  Returns `:disconnected` (or the `:disconnected` option value) during HTTP pre-render.
  """
  def use_hold(server, item_id, opts \\ []) do
    disconnected_val = Keyword.get(opts, :disconnected, :disconnected)
    sentinel = :__hold_disconnected__

    source = use_source({Filament.Observable.GenServer, server})

    item =
      use_value(source, fn
        :disconnected -> sentinel
        state -> Map.get(state, item_id)
      end)

    {held_qty, set_held_qty} = use_state(0)

    if item == sentinel do
      disconnected_val
    else
      owner_pid = current_context().owner_pid

      hold = fn qty ->
        case GenServer.call(server, {:filament_hold, item_id, qty, owner_pid}) do
          :ok -> set_held_qty.(held_qty + qty)
          {:error, reason} -> raise "hold denied for #{inspect(item_id)}: #{inspect(reason)}"
        end
      end

      release = fn qty ->
        GenServer.cast(server, {:filament_release_qty, item_id, qty, owner_pid})
        set_held_qty.(max(0, held_qty - qty))
      end

      {held_qty, item, hold, release}
    end
  end
end
