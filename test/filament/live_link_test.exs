defmodule Filament.LiveLinkTest do
  @moduledoc """
  `<a navigate>` and `<a patch>` in `~F` are HEEx's `<.link>`.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Diff

  defmodule Links do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:to, :any, default: "/vendors/acme")
      prop(:replace, :boolean, default: false)

      def render(%{to: to, replace: replace}) do
        ~F"""
        <nav>
          <a navigate="/vendors" class="v">Vendors</a>
          <a patch={to} replace={replace}>Acme</a>
          <a navigate={to} replace>Again</a>
        </nav>
        """
      end
    end
  end

  defp html(props) do
    for target <- [Filament.VNode, Filament.Web] do
      {tree, output, _} = Filament.Reconciler.mount(Links, props, target: target)
      Filament.Reconciler.unmount(tree)
      output |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
    end
  end

  test "renders LiveView's link attributes, as <.link> does" do
    for html <- html(%{}) do
      assert html =~ ~s(<a href="/vendors" data-phx-link="redirect" data-phx-link-state="push" class="v">Vendors</a>)
      assert html =~ ~s(<a href="/vendors/acme" data-phx-link="patch" data-phx-link-state="push">Acme</a>)
      assert html =~ ~s(<a href="/vendors/acme" data-phx-link="redirect" data-phx-link-state="replace">Again</a>)
    end
  end

  test "replace={true} replaces the history entry" do
    for html <- html(%{replace: true}) do
      assert html =~ ~s(<a href="/vendors/acme" data-phx-link="patch" data-phx-link-state="replace">Acme</a>)
    end
  end

  defmodule Listed do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        ~F"""
        <ul>
          <li :for={i <- 1..3}><a navigate={"/v/#{i}"}>{i}</a></li>
        </ul>
        """
      end
    end
  end

  defmodule HandWritten do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        ~F"""
        <ul>
          <li :for={i <- 1..3}><a href={"/v/#{i}"} data-phx-link="redirect" data-phx-link-state="push">{i}</a></li>
        </ul>
        """
      end
    end
  end

  test "sends what the attributes written out would: each row's path alone" do
    assert diff(Listed) == diff(HandWritten)
  end

  defp diff(component) do
    {_tree, rendered, _} = Filament.Reconciler.mount(component, %{}, target: Filament.Web)
    view = Filament.LiveView.render(%{__changed__: nil, _filament_rendered: rendered})
    prints = Diff.new_fingerprints()
    {diff, _, _} = Diff.render(%Phoenix.LiveView.Socket{}, view, prints, Diff.new_components())
    diff
  end

  for {source, message} <- [
        {~s(<a navigate="/a" patch="/b">x</a>), ~r/takes one of navigate and patch/},
        {~s(<a navigate="/a" href="/b">x</a>), ~r/takes its href from it/},
        {~s(<a navigate>x</a>), ~r/needs the path to go to/},
        {~s(<a href="/a" replace>x</a>), ~r/replace goes with navigate or patch/}
      ] do
    test "rejects #{source}" do
      source = """
      defmodule Filament.LiveLinkTest.Bad#{System.unique_integer([:positive])} do
        use Filament.Component

        defcomponent do
          def render(_props), do: ~F'#{unquote(source)}'
        end
      end
      """

      assert_raise Phoenix.LiveView.TagEngine.Tokenizer.ParseError, unquote(Macro.escape(message)), fn ->
        Code.compile_string(source, "bad.ex")
      end
    end
  end
end
