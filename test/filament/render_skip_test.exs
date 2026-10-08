defmodule Filament.RenderSkipTest do
  use ExUnit.Case, async: true

  import Filament.Test

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket

  defmodule Leaf do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string, required: true)
      prop(:on_pick, :any, default: nil)

      def render(%{label: label, on_pick: on_pick}) do
        send(self(), {:rendered, {:leaf, label}})
        pick = on_pick || fn -> :ok end
        ~F|<i id={"leaf-" <> label} on_click={pick}>{label}</i>|
      end
    end
  end

  defmodule Counter do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:test, :any, required: true)

      def render(%{test: test}) do
        {n, set_n} = use_state(0)
        send(self(), {:rendered, :counter})

        use_effect(
          fn ->
            send(test, {:effect, n})
            fn -> send(test, {:cleanup, n}) end
          end,
          [n]
        )

        ~F"""
        <span>
          <button id="inc" on_click={fn -> set_n.(n + 1) end}>{n}</button>
          {if rem(n, 2) == 0, do: ~F|<Filament.RenderSkipTest.Leaf label="even" />|}
        </span>
        """
      end
    end
  end

  defmodule Middle do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:test, :any, required: true)

      def render(%{test: test}) do
        {open, set_open} = use_state(false)
        send(self(), {:rendered, :middle})

        ~F"""
        <div>
          <button id="toggle" on_click={fn -> set_open.(!open) end}>{if open, do: "open", else: "shut"}</button>
          <Filament.RenderSkipTest.Counter test={test} />
        </div>
        """
      end
    end
  end

  defmodule Root do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:test, :any, required: true)

      def render(%{test: test}) do
        {n, set_n} = use_state(0)
        {picked, set_picked} = use_state(nil)
        send(self(), {:rendered, :root})

        ~F"""
        <main>
          <button id="same" on_click={fn -> set_n.(n) end}>same</button>
          <button id="bump" on_click={fn -> set_n.(n + 1) end}>{n}</button>
          <p id="picked">{inspect(picked)}</p>
          <Filament.RenderSkipTest.Leaf label="fixed" />
          <Filament.RenderSkipTest.Leaf label="callback" on_pick={fn -> set_picked.(:fixed) end} />
          <Filament.RenderSkipTest.Leaf label="moving" on_pick={fn -> set_picked.(n) end} />
          <Filament.RenderSkipTest.Middle test={test} />
        </main>
        """
      end
    end
  end

  defp renders do
    receive do
      {:rendered, who} -> [who | renders()]
    after
      0 -> []
    end
  end

  defp text(view, selector), do: view.rendered_html |> Floki.parse_fragment!() |> Floki.find(selector) |> Floki.text()

  setup do
    view = mount!(Root, %{test: self()})
    assert_receive {:effect, 0}

    assert Enum.sort(renders()) ==
             Enum.sort(
               [:root, :middle, :counter, {:leaf, "fixed"}, {:leaf, "callback"}, {:leaf, "moving"}] ++ [{:leaf, "even"}]
             )

    %{view: view}
  end

  test "setting state to the value it holds renders nothing", %{view: view} do
    view = click!(view, "#same")
    assert renders() == []
    assert text(view, "#bump") == "0"
  end

  test "a parent's state change skips children whose props are unchanged, closures included", %{view: view} do
    view = click!(view, "#bump")

    # "moving" captures n, so its closure prop changed; "callback" captures only
    # the setter, so it compares equal.
    assert Enum.sort(renders()) == Enum.sort([:root, {:leaf, "moving"}])
    assert text(view, "#bump") == "1"
    assert text(view, "main span button") == "0"

    view = click!(view, "#leaf-callback")
    assert text(view, "#picked") == ":fixed"
    view = click!(view, "#leaf-moving")
    assert text(view, "#picked") == "1"
  end

  test "a descendant's state change renders only that descendant", %{view: view} do
    view = click!(view, "#inc")

    assert renders() == [:counter]
    assert_receive {:cleanup, 0}
    assert_receive {:effect, 1}
    assert text(view, "#inc") == "1"
    assert text(view, "#toggle") == "shut"

    # Fibers that were skipped keep working handlers.
    view = click!(view, "#toggle")
    assert renders() == [:middle]
    assert text(view, "#toggle") == "open"
    assert text(view, "#inc") == "1"
  end

  test "a skipped parent still unmounts children its dirty descendant removed", %{view: view} do
    even_id = Enum.find(Map.keys(view.fiber_tree), &(String.contains?(&1, "Leaf[0]") and &1 =~ "Counter"))
    assert even_id

    view = click!(view, "#inc")
    refute Map.has_key?(view.fiber_tree, even_id)
    refute text(view, "#leaf-even") == "even"

    view = click!(view, "#inc")
    assert text(view, "#leaf-even") == "even"
    assert Enum.sort(renders()) == Enum.sort([:counter, :counter, {:leaf, "even"}])
    assert Enum.all?(view.fiber_tree, fn {_id, fiber} -> fiber.dirty == nil end)
  end

  defmodule KeyedRows do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:keys, :list, required: true)

      def render(%{keys: keys}) do
        ~F"""
        <ul>
          <Filament.RenderSkipTest.Leaf :for={key <- keys} :key={key} label={key} />
        </ul>
        """
      end
    end
  end

  test "reordering keyed children reuses them in the new order" do
    {tree, _, _} = Filament.Reconciler.mount(KeyedRows, %{keys: ["a", "b", "c"]}, owner_pid: self())
    assert Enum.sort(renders()) == [{:leaf, "a"}, {:leaf, "b"}, {:leaf, "c"}]

    {_tree, rendered, _} = Filament.Reconciler.update(tree, "root", %{keys: ["c", "a"]}, owner_pid: self())
    assert renders() == []

    assert rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary() =~
             ~r{<i id="leaf-c"[^>]*>c</i>\s*<i id="leaf-a"[^>]*>a</i>}
  end

  defmodule Host do
    @moduledoc false
    use Filament.LiveView

    def root_component, do: Root
  end

  test "a LiveView ignores a state message that changes nothing" do
    socket = %Socket{
      assigns: %{__changed__: %{}, test: self()},
      private: %{live_temp: %{}, lifecycle: Lifecycle.__struct__()}
    }

    {:ok, socket} = Host.mount(%{}, %{}, socket)
    renders()

    assert {:noreply, ^socket} = Host.handle_info({:filament_set_state, "root", 0, 0}, socket)
    assert renders() == []

    {:noreply, socket} = Host.handle_info({:filament_set_state, "root", 0, 1}, socket)
    assert Enum.sort(renders()) == Enum.sort([:root, {:leaf, "moving"}])
    assert elem(socket.assigns._filament_tree["root"].hook_slots[0], 0) == 1
  end
end
