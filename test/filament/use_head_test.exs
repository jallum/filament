defmodule Filament.UseHeadTest do
  use ExUnit.Case, async: true

  import Filament.Test

  defmodule Product do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:name, :any, required: true)

      def render(%{name: name}) do
        use_head(
          title: name && "#{name} · Shop",
          canonical: name && "https://shop.test/#{name}",
          meta: [description: name]
        )

        ~F"<h1>{name}</h1>"
      end
    end
  end

  defmodule Renamer do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        {name, set_name} = use_state("socks")
        use_head(title: "#{name} · Shop")
        rename = fn -> set_name.("scarves") end

        ~F"""
        <button class="rename" on_click={rename}>{name}</button>
        """
      end
    end
  end

  defmodule Shelf do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props) do
        use_head(canonical: "https://shop.test/shelf")
        ~F"<section><Renamer /></section>"
      end
    end
  end

  defmodule Layout do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:show, :boolean, default: true)
      prop(:name, :any, default: "boots")

      def render(%{show: show, name: name}) do
        use_head(title: "Shop", meta: [description: "Everything we sell", "og:site_name": "Shop"])
        {count, set_count} = use_state(0)
        bump = fn -> set_count.(&(&1 + 1)) end

        ~F"""
        <main>
          <button on_click={bump}>{count}</button>
          {if show do}
            <Product name={name} />
          {end}
        </main>
        """
      end
    end
  end

  test "the deepest declaration of each wins, meta merged by name" do
    view = mount!(Layout, %{})

    assert head(view) == %{
             title: "boots · Shop",
             canonical: "https://shop.test/boots",
             meta: %{"description" => "boots", "og:site_name" => "Shop"}
           }
  end

  test "a nil declares nothing, leaving what's above" do
    view = mount!(Layout, %{name: nil})

    assert head(view) == %{
             title: "Shop",
             canonical: nil,
             meta: %{"description" => "Everything we sell", "og:site_name" => "Shop"}
           }
  end

  test "follows the tree as it changes, and a reused child keeps its declaration" do
    view = mount!(Layout, %{})
    view = click!(view, "button")
    assert head(view).title == "boots · Shop"

    view = put_props(view, name: "hats")
    assert head(view).canonical == "https://shop.test/hats"

    view = put_props(view, show: false)
    assert head(view).title == "Shop"
    assert head(view).canonical == nil
  end

  test "a child's own render changes the head, its ancestors' declarations kept" do
    view = mount!(Shelf, %{})
    assert head(view) == %{title: "socks · Shop", canonical: "https://shop.test/shelf", meta: %{}}

    view = click!(view, "button.rename")
    assert head(view) == %{title: "scarves · Shop", canonical: "https://shop.test/shelf", meta: %{}}
  end

  test "raises on options it doesn't take" do
    for opts <- [[titel: "x"], [title: :x], [meta: [description: 1]], [meta: "x"]] do
      assert_raise ArgumentError, ~r/use_head/, fn -> Filament.Head.declaration!(opts) end
    end
  end

  test "renders the canonical link and meta tags, Open Graph's by property" do
    head = %{title: "x", canonical: "https://shop.test/a", meta: %{"description" => "d", "og:title" => "t"}}

    assert Filament.Head.tags(head) == [
             {"link", [{"rel", "canonical"}, {"href", "https://shop.test/a"}]},
             {"meta", [{"name", "description"}, {"content", "d"}]},
             {"meta", [{"property", "og:title"}, {"content", "t"}]}
           ]
  end
end
