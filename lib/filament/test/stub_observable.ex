defmodule Filament.Test.StubObservable do
  @moduledoc false

  use Filament.Observable.GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    stub_fn = Keyword.fetch!(opts, :stub_fn)
    {:ok, stub_fn.(nil)}
  end

  @impl GenServer
  def handle_call({:push, new_state}, _from, _state) do
    notify_observers(new_state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end
end
