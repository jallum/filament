defmodule Filament.InlineChildrenTest do
  use ExUnit.Case, async: true

  alias Filament.Reconciler
  alias Phoenix.HTML.Safe

  defmodule Page do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:children, :any, required: true)
      def render(%{children: children}), do: ~F"<main>{children}</main>"
    end
  end

  defmodule Screen do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:x, :any, default: 1)
      def render(%{x: x}), do: ~F"<Filament.InlineChildrenTest.Page><h1>{x}</h1></Filament.InlineChildrenTest.Page>"
    end
  end

  defmodule Button do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_) do
        {count, set_count} = use_state(0)
        ~F|<button id="child" on_click={fn -> set_count.(count + 1) end}>{count}</button>|
      end
    end
  end

  defmodule Nested do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_) do
        {count, set_count} = use_state(0)

        ~F"""
        <Filament.InlineChildrenTest.Page>
          <Filament.InlineChildrenTest.Page>
            <button id="parent" on_click={fn -> set_count.(count + 1) end}>{count}</button>
            <Filament.InlineChildrenTest.Button />
          </Filament.InlineChildrenTest.Page>
        </Filament.InlineChildrenTest.Page>
        """
      end
    end
  end

  test "nested inline children preserve parent and child event ownership and state" do
    view = Filament.Test.mount!(Nested, %{})
    assert view.rendered_html =~ "<main>"
    view = Filament.Test.click!(view, "#child")
    assert text(view, "#child") == "1"
    assert text(view, "#parent") == "0"
    view = Filament.Test.click!(view, "#parent")
    assert text(view, "#parent") == "1"
    assert text(view, "#child") == "1"
  end

  test "inline markup becomes the children prop without assigns in scope" do
    {tree, rendered, _} = Reconciler.mount(Screen, %{x: "<one>"}, owner_pid: self())
    assert html(rendered) == "<main><h1>&lt;one&gt;</h1></main>"
    {_, rendered, _} = Reconciler.update(tree, "root", %{x: "two"}, owner_pid: self())
    assert html(rendered) == "<main><h1>two</h1></main>"
  end

  defmodule Card do
    @moduledoc false
    use Phoenix.Component

    def card(assigns), do: ~H"<aside>{render_slot(@inner_block)}</aside>"
  end

  test "function components keep Phoenix inner-block slots" do
    import Filament.SigilF

    assigns = %{__changed__: nil, x: "hello"}

    rendered = ~F"""
    <Filament.InlineChildrenTest.Card.card><h1>{@x}</h1></Filament.InlineChildrenTest.Card.card>
    """

    assert String.trim(html(rendered)) == "<aside><h1>hello</h1></aside>"
  end

  defp text(view, selector), do: view.rendered_html |> Floki.parse_fragment!() |> Floki.find(selector) |> Floki.text()

  defp html(rendered), do: rendered |> Safe.to_iodata() |> IO.iodata_to_binary()
end
