defmodule Filament.StateHelper do
  @moduledoc false

  # The message the use_state setter at this slot would send.
  def set_state(tree, fiber_id, slot_index, value) do
    {:state, _value, _setter, token} = tree[fiber_id].hook_slots[slot_index]
    {:filament_set_state, fiber_id, slot_index, token, value}
  end

  def apply_set_state(tree, fiber_id, slot_index, value) do
    Filament.LiveView.apply_message(tree, set_state(tree, fiber_id, slot_index, value))
  end
end
