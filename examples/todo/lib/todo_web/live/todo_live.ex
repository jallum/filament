defmodule TodoWeb.TodoLive do
  @moduledoc false
  # Each visitor's list starts its own store, which the HTTP render would
  # start too and leave behind.
  use Filament.LiveView, static_subscribe: false

  def root_component, do: TodoWeb.Components.TodoList
end
