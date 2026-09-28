defmodule Filament.Bench.Store do
  @moduledoc false
  use Filament.Observable.GenServer

  alias Filament.Bench.Compat

  def start_link, do: GenServer.start_link(__MODULE__, 0)
  def init(value), do: {:ok, value}

  def handle_call({:write, value}, _from, _) do
    notify_observers(value)
    {:reply, :ok, value}
  end

  def handle_call(:subscription_count, _from, value) do
    {:reply, Compat.subscription_count(), value}
  end
end

defmodule Filament.Bench.Row do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:id, :integer, required: true)

    def render(%{id: id}) do
      {value, set_value} = use_state(id)

      ~F"""
      <li data-id={id}><button on_click={fn -> set_value.(value + 1) end}>{value}</button></li>
      """
    end
  end
end

defmodule Filament.Bench.Rows do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:items, :list, required: true)

    def render(%{items: items}) do
      ~F"""
      <ul><Filament.Bench.Row :for={id <- items} :key={id} id={id} /></ul>
      """
    end
  end
end

defmodule Filament.Bench.ValueRow do
  @moduledoc false
  use Filament.Component

  alias Filament.Bench.Compat

  defcomponent do
    prop(:id, :integer, required: true)
    prop(:server, :any, required: true)

    def render(%{id: id, server: server}) do
      value = Compat.read(server)
      ~F"<li data-id={id}>{value}</li>"
    end
  end
end

defmodule Filament.Bench.ValueRows do
  @moduledoc false
  use Filament.Component

  defcomponent do
    prop(:items, :list, required: true)
    prop(:server, :any, required: true)

    def render(%{items: items, server: server}) do
      ~F"""
      <ul><Filament.Bench.ValueRow :for={id <- items} :key={id} id={id} server={server} /></ul>
      """
    end
  end
end
