defmodule TodoWeb.TodoLive do
  @moduledoc false
  use Filament.LiveView

  def root_component, do: TodoWeb.Components.TodoList
end
