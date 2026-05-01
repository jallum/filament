defmodule Filament.TestTest do
  use ExUnit.Case, async: true
  import Filament.Test
  alias Filament.Test.Stub

  defmodule CounterComp do
    use Filament.Component
    import Filament.Hooks

    defcomponent Counter do
      prop(:initial, :integer, default: 0)

      def render(assigns) do
        {count, set_count} = use_state(Map.get(assigns, :initial, 0))
        assigns = Map.merge(assigns, %{count: count, on_click: fn -> set_count.(count + 1) end})

        ~F"""
        <div>
          <span id="count">Count: {@count}</span>
          <button on_click={@on_click}>+</button>
        </div>
        """
      end
    end
  end

  defmodule ClassComp do
    use Filament.Component

    defcomponent Class do
      prop(:active, :boolean, default: false)

      def render(assigns) do
        class = if Map.get(assigns, :active), do: "active bold", else: "inactive"
        assigns = Map.put(assigns, :class, class)

        ~F"""
        <div class={@class}>Hello</div>
        """
      end
    end
  end

  defmodule ObservableComp do
    use Filament.Component
    import Filament.Hooks

    defcomponent Observable do
      prop(:server, :term, required: true)

      def render(assigns) do
        value = use_observable(Map.get(assigns, :server))
        assigns = Map.put(assigns, :value, value)

        ~F"""
        <div id="value">{@value}</div>
        """
      end
    end
  end

  defmodule FormComp do
    use Filament.Component

    defcomponent Form do
      prop(:on_submit, :function, required: true)

      def render(assigns) do
        ~F"""
        <form on_submit={@on_submit}>
          <input name="name" />
          <button>Submit</button>
        </form>
        """
      end
    end
  end

  test "1. mount returns rendered HTML" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})
    assert render_text(view) =~ "Count: 0"
  end

  test "2. click updates state and re-renders" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})

    {:ok, view} = click(view, "button")
    assert render_text(view) =~ "Count: 1"

    {:ok, view} = click(view, "button")
    assert render_text(view) =~ "Count: 2"
  end

  test "3. has_class? true" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "active") == true
    assert has_class?(view, "div", "bold") == true
  end

  test "4. has_class? false" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "missing") == false
  end

  test "5. has_class? raises on missing selector" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})

    assert_raise RuntimeError, ~r/no element matched selector/, fn ->
      has_class?(view, "span", "active")
    end
  end

  test "6. stub observable injected at mount" do
    {:ok, view} =
      mount(ObservableComp.Observable, %{server: :my_server},
        stub: [{:my_server, fn _req -> 42 end}]
      )

    assert render_text(view) =~ "42"
  end

  test "7. stub push updates rendered output" do
    {:ok, view} =
      mount(ObservableComp.Observable, %{server: :my_server},
        stub: [{:my_server, fn _req -> 0 end}]
      )

    assert render_text(view) =~ "0"

    stub_pid = view.stubs[:my_server]
    Stub.push(stub_pid, 99)
    view = Filament.Test.update(view)
    assert render_text(view) =~ "99"
  end

  test "8. click on nonexistent selector" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})
    assert click(view, "#nonexistent") == {:error, {:no_element, "#nonexistent"}}
  end

  test "9. submit delivers params to handler" do
    test_pid = self()

    handler = fn params ->
      send(test_pid, {:submitted, params})
    end

    {:ok, view} = mount(FormComp.Form, %{on_submit: handler})
    {:ok, _view} = submit(view, "form", %{"name" => "Alice"})

    assert_receive {:submitted, %{"name" => "Alice"}}
  end
end
