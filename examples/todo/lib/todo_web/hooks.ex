defmodule TodoWeb.Hooks do
  @moduledoc "Domain hook for the component-owned todo store."

  import Filament.Hooks, only: [use_source: 1, use_value: 2]

  alias Todo.Store

  @doc "Own a todo store and return the values needed by the list."
  def use_todos(filter) do
    source =
      use_source(fn ->
        {:ok, pid} = Store.start_link([])
        Store.cell(pid)
      end)

    {filtered, active_count, all_completed, any_todos} =
      use_value(source, fn
        :disconnected ->
          {[], 0, false, false}

        todos ->
          {
            apply_filter(todos, filter),
            Enum.count(todos, &(!&1.completed)),
            todos != [] and Enum.all?(todos, & &1.completed),
            todos != []
          }
      end)

    %{
      store: if(source, do: source.data),
      filtered: filtered,
      active_count: active_count,
      all_completed: all_completed,
      any_todos: any_todos
    }
  end

  defp apply_filter(todos, :all), do: todos
  defp apply_filter(todos, :active), do: Enum.reject(todos, & &1.completed)
  defp apply_filter(todos, :completed), do: Enum.filter(todos, & &1.completed)
end
