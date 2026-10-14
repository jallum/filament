defmodule Filament.Test.Stub do
  @moduledoc """
  Convenience API for creating and driving observable stubs in tests.

  Start a stub and pass its pid to a domain hook through component props:

      {:ok, stub} = Filament.Test.Stub.start(fn _ -> %{items: []} end)
      view = Filament.Test.mount!(CartBadge, %{cart: stub})

  The hook constructs `MyServer.cell(stub)` (or
  `Filament.Source.new(Filament.Observable.GenServer, stub)`) and reads it
  with `use_value/2`. Mount does not replace server references automatically.

  To push an update after mount:

      Filament.Test.Stub.push(stub_pid, %{items: ["x"], total: 10})

  """

  alias Filament.Test.StubObservable

  @doc """
  Start a stub observable backed by `stub_fn`.
  `stub_fn` receives the subscription request and returns the initial value.

  Returns `{:ok, pid}`.
  """
  @spec start(stub_fn :: (request :: term() -> initial_value :: term()), opts :: keyword()) ::
          {:ok, pid()}
  def start(stub_fn, opts \\ []) do
    StubObservable.start_link([stub_fn: stub_fn] ++ opts)
  end

  @doc """
  Push `new_state` to all current subscribers of the stub.
  Triggers the same notification path as a real observable's notify_observers/1,
  including transport projection and equality checks.
  """
  @spec push(stub :: pid(), new_state :: term()) :: :ok
  def push(stub, new_state) do
    GenServer.call(stub, {:push, new_state})
  end

  @doc """
  Read back the last state that was pushed to (or initially set in) the stub.
  """
  @spec state(stub :: pid()) :: term()
  def state(stub) do
    GenServer.call(stub, :state)
  end

  @doc """
  Build a map of server labels to stub pids for explicit test wiring.
  Starts a StubObservable for each {server, stub_fn} pair.
  Returns `{stubs_map, pids}` where `stubs_map` is `%{server => pid}` and
  `pids` is the list of started stub pids (for cleanup in on_exit).
  """
  @spec build([{server :: term(), stub_fn :: function()}]) ::
          {stubs_map :: %{term() => pid()}, pids :: [pid()]}
  def build(stub_specs) do
    Enum.reduce(stub_specs, {%{}, []}, fn {server, stub_fn}, {map, pids} ->
      {:ok, pid} = start(stub_fn)
      {Map.put(map, server, pid), [pid | pids]}
    end)
  end
end
