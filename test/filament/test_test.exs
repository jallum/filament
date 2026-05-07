defmodule Filament.TestTest do
  use ExUnit.Case, async: true

  import Filament.Test

  alias Filament.Test.Stub

  defmodule CounterComp do
    @moduledoc false
    use Filament.Component

    defcomponent Counter do
      prop(:initial, :integer, default: 0)

      def render(%{initial: initial}) do
        {count, set_count} = use_state(initial)
        on_click = fn -> set_count.(count + 1) end

        ~F"""
        <div>
          <span id="count">Count: {count}</span>
          <button on_click={on_click}>+</button>
        </div>
        """
      end
    end
  end

  defmodule ClassComp do
    @moduledoc false
    use Filament.Component

    defcomponent Class do
      prop(:active, :boolean, default: false)

      def render(%{active: active}) do
        class = if active, do: "active bold", else: "inactive"

        ~F"""
        <div class={class}>Hello</div>
        """
      end
    end
  end

  defmodule ObservableComp do
    @moduledoc false
    use Filament.Component

    defcomponent Observable do
      prop(:server, :term, required: true)

      def render(%{server: server}) do
        value =
          use_observable(server, fn
            :disconnected -> nil
            s -> s
          end)

        ~F"""
        <div id="value">{value}</div>
        """
      end
    end
  end

  defmodule InputComp do
    @moduledoc false
    use Filament.Component

    defcomponent Input do
      def render(_assigns) do
        {last_change, set_last_change} = use_state(nil)
        {last_blur, set_last_blur} = use_state(nil)
        {last_key, set_last_key} = use_state(nil)

        ~F"""
        <div>
          <input id="field"
            on_change={fn params -> set_last_change.(params["value"]) end}
            on_blur={fn -> set_last_blur.("blurred") end}
            on_keydown={fn params -> set_last_key.(params["key"]) end}
          />
          <span id="change">{last_change}</span>
          <span id="blur">{last_blur}</span>
          <span id="key">{last_key}</span>
        </div>
        """
      end
    end
  end

  defmodule FormComp do
    @moduledoc false
    use Filament.Component

    defcomponent Form do
      prop(:on_submit, :function, required: true)

      def render(%{on_submit: on_submit}) do
        ~F"""
        <form on_submit={on_submit}>
          <input name="name" />
          <button>Submit</button>
        </form>
        """
      end
    end
  end

  test "mount returns rendered HTML" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})
    assert render_text(view) =~ "Count: 0"
  end

  test "click updates state and re-renders" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})

    {:ok, view} = click(view, "button")
    assert render_text(view) =~ "Count: 1"

    {:ok, view} = click(view, "button")
    assert render_text(view) =~ "Count: 2"
  end

  test "has_class? true" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "active") == true
    assert has_class?(view, "div", "bold") == true
  end

  test "has_class? false" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "missing") == false
  end

  test "has_class? raises on missing selector" do
    {:ok, view} = mount(ClassComp.Class, %{active: true})

    assert_raise RuntimeError, ~r/no element matched selector/, fn ->
      has_class?(view, "span", "active")
    end
  end

  test "stub observable injected at mount" do
    {:ok, view} =
      mount(ObservableComp.Observable, %{server: :my_server}, stub: [{:my_server, fn _req -> 42 end}])

    assert render_text(view) =~ "42"
  end

  test "stub push updates rendered output" do
    {:ok, view} =
      mount(ObservableComp.Observable, %{server: :my_server}, stub: [{:my_server, fn _req -> 0 end}])

    assert render_text(view) =~ "0"

    stub_pid = view.stubs[:my_server]
    Stub.push(stub_pid, 99)
    view = Filament.Test.update(view)
    assert render_text(view) =~ "99"
  end

  test "click on nonexistent selector" do
    {:ok, view} = mount(CounterComp.Counter, %{initial: 0})
    assert click(view, "#nonexistent") == {:error, {:no_element, "#nonexistent"}}
  end

  test "change delivers params to handler and re-renders" do
    {:ok, view} = mount(InputComp.Input, %{})
    {:ok, view} = change(view, "#field", %{"value" => "hello"})
    assert render_text(view) =~ "hello"
  end

  test "blur fires handler and re-renders" do
    {:ok, view} = mount(InputComp.Input, %{})
    {:ok, view} = blur(view, "#field")
    assert render_text(view) =~ "blurred"
  end

  test "key_down (element-scoped) delivers key string and re-renders" do
    {:ok, view} = mount(InputComp.Input, %{})
    {:ok, view} = key_down(view, "#field", "Tab")
    assert render_text(view) =~ "Tab"
  end

  test "change on nonexistent selector returns error" do
    {:ok, view} = mount(InputComp.Input, %{})
    assert change(view, "#nope", %{}) == {:error, {:no_element, "#nope"}}
  end

  test "blur on nonexistent selector returns error" do
    {:ok, view} = mount(InputComp.Input, %{})
    assert blur(view, "#nope") == {:error, {:no_element, "#nope"}}
  end

  test "key_down (element-scoped) on nonexistent selector returns error" do
    {:ok, view} = mount(InputComp.Input, %{})
    assert key_down(view, "#nope", "Tab") == {:error, {:no_element, "#nope"}}
  end

  test "submit delivers params to handler" do
    test_pid = self()

    handler = fn params ->
      send(test_pid, {:submitted, params})
    end

    {:ok, view} = mount(FormComp.Form, %{on_submit: handler})
    {:ok, _view} = submit(view, "form", %{"name" => "Alice"})

    assert_receive {:submitted, %{"name" => "Alice"}}
  end
end
