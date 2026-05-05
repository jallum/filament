defmodule Filament.Test.Rung3Test do
  use ExUnit.Case, async: true

  import Filament.Test

  defmodule TestCounter do
    @moduledoc false
    use Filament.Observable.GenServer

    def start_link(n), do: GenServer.start_link(__MODULE__, n)
    def init(n), do: {:ok, n}
    def increment(pid), do: GenServer.call(pid, :increment)

    def handle_call(:increment, _from, n) do
      new_n = n + 1
      notify_observers(new_n)
      {:reply, :ok, new_n}
    end
  end

  defmodule CountingComp do
    @moduledoc false
    use Filament.Component

    defcomponent Counter do
      prop(:server, :term, required: true)

      def render(%{server: server}) do
        count =
          use_observable(server, fn
            :disconnected -> nil
            s -> s
          end)

        ~F"""
        <span id="count">Count: {count}</span>
        """
      end
    end
  end

  test "1. update/1 processes pending message" do
    counter = start_supervised!({TestCounter, 0})

    {:ok, view} = mount(CountingComp.Counter, %{server: counter})
    assert render_text(view) =~ "Count: 0"

    TestCounter.increment(counter)
    view = Filament.Test.update(view)
    assert render_text(view) =~ "Count: 1"
  end

  test "2. update/1 is idempotent with empty mailbox" do
    counter = start_supervised!({TestCounter, 0})
    {:ok, view} = mount(CountingComp.Counter, %{server: counter})

    html_before = view.rendered_html
    view = Filament.Test.update(view)
    html_after = view.rendered_html

    assert html_before == html_after
  end

  test "3. eventually/2 passes when condition met" do
    counter = start_supervised!({TestCounter, 0})
    {:ok, view} = mount(CountingComp.Counter, %{server: counter})

    spawn(fn ->
      Process.sleep(50)
      TestCounter.increment(counter)
    end)

    assert :ok =
             Filament.Test.eventually(
               fn ->
                 view = Filament.Test.update(view)
                 render_text(view) =~ "Count: 1"
               end,
               timeout: 500
             )
  end

  test "4. eventually/2 raises on timeout" do
    counter = start_supervised!({TestCounter, 0})
    {:ok, view} = mount(CountingComp.Counter, %{server: counter})

    assert_raise RuntimeError, ~r/timed out after 100ms/, fn ->
      Filament.Test.eventually(
        fn ->
          view = Filament.Test.update(view)
          render_text(view) =~ "Count: 1"
        end,
        timeout: 100
      )
    end
  end

  test "5. multiple increments before update" do
    counter = start_supervised!({TestCounter, 0})
    {:ok, view} = mount(CountingComp.Counter, %{server: counter})

    TestCounter.increment(counter)
    TestCounter.increment(counter)
    TestCounter.increment(counter)

    view = Filament.Test.update(view)
    assert render_text(view) =~ "Count: 3"
  end
end
