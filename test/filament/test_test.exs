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

  defmodule KeyedComp do
    @moduledoc false
    use Filament.Component

    defcomponent Row do
      prop(:label, :string)

      def render(%{label: label}) do
        {clicked, set_clicked} = use_state(false)

        ~F"""
        <button data-key={label} on_click={fn -> set_clicked.(true) end}>{label}{if clicked, do: " clicked"}</button>
        """
      end
    end

    defcomponent Rows do
      prop(:keys, :list)

      def render(%{keys: keys}) do
        ~F"""
        <div>
          <Filament.TestTest.KeyedComp.Row :for={key <- keys} :key={key} label={key} />
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
        cell = Filament.Source.new(Filament.Observable.GenServer, server)

        value =
          use_value(cell, fn
            :disconnected -> nil
            s -> s
          end)

        ~F"""
        <div id="value">{value}</div>
        """
      end
    end
  end

  defmodule CatalogComp do
    @moduledoc false
    use Filament.Observable.GenServer
    use Filament.Component

    alias Filament.TestTest.CatalogComp

    def start_link(phase), do: GenServer.start_link(__MODULE__, phase)
    def label(server), do: GenServer.call(server, :label)

    @impl GenServer
    def init(phase), do: {:ok, phase}

    @impl GenServer
    def handle_call(:label, _from, phase), do: {:reply, "catalog", phase}

    defcomponent Phase do
      prop(:catalog, :term, required: true)

      def render(%{catalog: catalog}) do
        phase =
          use_value(CatalogComp.cell(catalog), fn
            :disconnected -> nil
            p -> p
          end)

        ~F"<p>{phase}</p>"
      end
    end

    defcomponent Page do
      prop(:catalog, :term, required: true)

      def render(%{catalog: catalog}) do
        ~F"""
        <h1>{CatalogComp.label(catalog)}</h1>
        <CatalogComp.Phase catalog={catalog} />
        """
      end
    end
  end

  defmodule ChainComp do
    @moduledoc false
    use Filament.Component

    defcomponent Chain do
      prop(:forever, :boolean, default: false)

      def render(%{forever: forever}) do
        {step, set_step} = use_state(0)
        use_effect(fn -> if step < 3 or forever, do: set_step.(step + 1) end, [step])
        ~F"<p>step {step}</p>"
      end
    end
  end

  defmodule EchoComp do
    @moduledoc false
    use Filament.Component

    defcomponent Echo do
      prop(:n, :integer, required: true)

      def render(%{n: n}) do
        {seen, set_seen} = use_state(nil)
        use_effect(fn -> set_seen.(n) end, [n])
        ~F"<p>seen {seen}</p>"
      end
    end
  end

  defmodule KeyModalComp do
    @moduledoc false
    use Filament.Component

    defcomponent KeyModal do
      def render(_assigns) do
        {last_event, set_last_event} = use_state(nil)

        ~F"""
        <div on_key={fn key, mods -> set_last_event.({key, mods}) end}>
          <span id="last-key">{inspect(last_event)}</span>
        </div>
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
          <input
            id="field"
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
    view = mount!(CounterComp.Counter, %{initial: 0})
    assert render_text(view) =~ "Count: 0"
  end

  test "click updates state and re-renders" do
    view = CounterComp.Counter |> mount!(%{initial: 0}) |> click!("button")
    assert render_text(view) =~ "Count: 1"

    view = click!(view, "button")
    assert render_text(view) =~ "Count: 2"
  end

  test "put_props/2 renders the root again with the props merged in" do
    view = ClassComp.Class |> mount!(%{}) |> put_props(active: true)
    assert has_class?(view, "div", "active")
    assert view |> put_props(%{active: false}) |> has_class?("div", "inactive")
  end

  test "put_props/2 keeps the components' state" do
    view =
      KeyedComp.Rows
      |> mount!(%{keys: ["a", "b"]})
      |> click!(~s(button[data-key="a"]))
      |> put_props(keys: ["b", "a", "c"])

    assert render_text(view) == "ba clickedc"
  end

  test "has_class? true" do
    view = mount!(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "active") == true
    assert has_class?(view, "div", "bold") == true
  end

  test "has_class? false" do
    view = mount!(ClassComp.Class, %{active: true})
    assert has_class?(view, "div", "missing") == false
  end

  test "has_class? raises on missing selector" do
    view = mount!(ClassComp.Class, %{active: true})

    assert_raise RuntimeError, ~r/no element matched selector/, fn ->
      has_class?(view, "span", "active")
    end
  end

  test "stub observable injected at mount" do
    {:ok, stub} = Stub.start(fn _req -> 42 end)
    {:ok, view} = mount(ObservableComp.Observable, %{server: stub})

    assert render_text(view) =~ "42"
  end

  defmodule StaticComp do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:server, :term, required: true)
      prop(:test_pid, :any, required: true)

      def render(%{server: server, test_pid: test_pid}) do
        use_effect(fn -> send(test_pid, :effect_ran) end, [])

        started =
          use_source(fn ->
            send(test_pid, :factory_called)
            Filament.Source.new(Filament.Observable.GenServer, server)
          end)

        ready = Filament.Source.new(Filament.Observable.GenServer, server)

        started_value =
          use_value(started, fn
            :disconnected -> :disconnected
            s -> s
          end)

        ready_value =
          use_value(ready, fn
            :disconnected -> :disconnected
            s -> s
          end)

        ~F"""
        <p>{started_value} {ready_value}</p>
        """
      end
    end
  end

  test "static: renders as an HTTP render does, starting nothing" do
    {:ok, stub} = Stub.start(fn _req -> 42 end)
    {:ok, view} = mount(StaticComp, %{server: stub, test_pid: self()}, static: true)

    assert render_text(view) == "disconnected 42"
    refute_received :factory_called
    refute_received :effect_ran

    Stub.push(stub, 99)
    refute_receive {:cell_update, _, _}, 50
  end

  test "stub push updates rendered output" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)
    {:ok, view} = mount(ObservableComp.Observable, %{server: stub})

    assert render_text(view) =~ "0"

    Stub.push(stub, 99)
    view = Filament.Test.update(view)
    assert render_text(view) =~ "99"
  end

  test "cells: answers a server's subscriptions from a stub while calls reach the server" do
    {:ok, catalog} = CatalogComp.start_link(:ready)
    {:ok, stub} = Stub.start(fn _req -> :scanning end)

    view = mount!(CatalogComp.Page, %{catalog: catalog}, cells: %{catalog => stub})
    assert render_text(view) =~ "catalog"
    assert render_text(view) =~ "scanning"

    Stub.push(stub, :matching)
    view = Filament.Test.update(view)
    assert render_text(view) =~ "matching"

    assert cell_subscribers(catalog) == %{}
    assert map_size(cell_subscribers(stub)) == 1

    unmount(view)
    assert cell_subscribers(stub) == %{}
  end

  defp cell_subscribers(server) do
    # Wait for casts already sent, such as an unsubscribe.
    :sys.get_state(server)
    {:dictionary, dictionary} = Process.info(server, :dictionary)
    Keyword.get(dictionary, :__filament_cell_subscribers__, %{})
  end

  test "mount/3 renders until effects stop setting state" do
    assert ChainComp.Chain |> mount!(%{}) |> render_text() == "step 3"
  end

  test "mount/3 raises for a view that never stops setting its own state" do
    assert_raise RuntimeError, ~r/kept sending itself messages/, fn -> mount(ChainComp.Chain, %{forever: true}) end
  end

  test "update/1 and put_props/2 show the state their render's effects set" do
    view = mount!(EchoComp.Echo, %{n: 1})
    assert render_text(view) == "seen 1"
    assert view |> put_props(n: 2) |> render_text() == "seen 2"
    assert view |> update() |> render_text() == "seen 1"
  end

  test "await/3 returns the view once its condition holds, waking on messages sent later" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)
    view = mount!(ObservableComp.Observable, %{server: stub})

    spawn(fn ->
      Process.sleep(20)
      Stub.push(stub, 7)
    end)

    view = await(view, &(render_text(&1) == "7"), interval: 5_000)
    assert render_text(view) == "7"
  end

  test "await/3 raises with the view's text when its condition doesn't hold in time" do
    {:ok, stub} = Stub.start(fn _req -> 0 end)
    view = mount!(ObservableComp.Observable, %{server: stub})

    error = assert_raise ExUnit.AssertionError, fn -> await(view, &(render_text(&1) == "7"), timeout: 30) end
    assert error.message =~ "timed out after 30ms"
    assert error.message =~ "0"
  end

  test "click on nonexistent selector" do
    view = mount!(CounterComp.Counter, %{initial: 0})
    assert click(view, "#nonexistent") == {:error, {:no_element, "#nonexistent"}}
  end

  test "a keyed child's handler is found whatever its key holds, colons too" do
    keys = ["plain", "type: fmj", "a:1", "x:"]
    view = mount!(KeyedComp.Rows, %{keys: keys})

    Enum.reduce(keys, view, fn key, view ->
      refute render_text(view) =~ "#{key} clicked"
      view = click!(view, ~s(button[data-key="#{key}"]))
      assert render_text(view) =~ "#{key} clicked"
      view
    end)
  end

  test "key_down delivers key string and %Filament.KeyModifiers{} to the handler" do
    view = KeyModalComp.KeyModal |> mount!(%{}) |> key_down!("Escape")
    assert render_text(view) =~ ~s({"Escape", %Filament.KeyModifiers{)

    view = key_down!(view, "s", ctrl: true)
    assert render_text(view) =~ ~s({"s", %Filament.KeyModifiers{)
    assert render_text(view) =~ "ctrl: true"
  end

  test "change delivers params to handler and re-renders" do
    view = InputComp.Input |> mount!(%{}) |> change!("#field", %{"value" => "hello"})
    assert render_text(view) =~ "hello"
  end

  test "blur fires handler and re-renders" do
    view = InputComp.Input |> mount!(%{}) |> blur!("#field")
    assert render_text(view) =~ "blurred"
  end

  test "key_down (element-scoped) delivers key string and re-renders" do
    view = InputComp.Input |> mount!(%{}) |> key_down!("#field", "Tab")
    assert render_text(view) =~ "Tab"
  end

  test "change on nonexistent selector returns error" do
    view = mount!(InputComp.Input, %{})
    assert change(view, "#nope", %{}) == {:error, {:no_element, "#nope"}}
  end

  test "blur on nonexistent selector returns error" do
    view = mount!(InputComp.Input, %{})
    assert blur(view, "#nope") == {:error, {:no_element, "#nope"}}
  end

  test "key_down (element-scoped) on nonexistent selector returns error" do
    view = mount!(InputComp.Input, %{})
    assert key_down(view, "#nope", "Tab") == {:error, {:no_element, "#nope"}}
  end

  test "submit delivers params to handler" do
    test_pid = self()

    handler = fn params ->
      send(test_pid, {:submitted, params})
    end

    FormComp.Form |> mount!(%{on_submit: handler}) |> submit!("form", %{"name" => "Alice"})

    assert_receive {:submitted, %{"name" => "Alice"}}
  end

  test "bang variants return view directly and enable pipelining" do
    view =
      CounterComp.Counter
      |> mount!(%{initial: 0})
      |> click!("button")
      |> click!("button")
      |> click!("button")

    assert render_text(view) =~ "Count: 3"
  end

  test "bang variant raises on error" do
    view = mount!(CounterComp.Counter, %{initial: 0})
    assert_raise RuntimeError, ~r/click!.*failed/, fn -> click!(view, "#nope") end
  end
end
