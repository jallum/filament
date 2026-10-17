defmodule Filament.TagEngine.SlotProviderTest do
  @moduledoc """
  opi-lzr.3: Provider-side slot render site.

  Verifies that self-closing `<:slot_name />` inside a component's render/1
  template compiles to a `{:slot, name, entries, default}` vnode that looks up
  slot entries from the component's assigns map at runtime.
  """
  use ExUnit.Case, async: true

  alias Filament.Slot.Entry
  alias Filament.TagEngine

  defmodule Fallback do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props), do: ~F"<em>fallback</em>"
    end
  end

  defmodule Card do
    @moduledoc false
    use Filament.Component

    defcomponent do
      slot(:footer, default: Filament.TagEngine.SlotProviderTest.Fallback)
      slot(:item)

      def render(props) do
        ~F"""
        <div>footers={length(Map.get(props, :footer, []))} children={inspect(Map.has_key?(props, :children))}</div>
        <ul><:item /></ul><p><:footer /></p>
        """
      end
    end
  end

  defmodule Page do
    @moduledoc false
    use Filament.Component

    defcomponent do
      slot(:title)
      prop(:empty_footer, :boolean, default: false)

      def render(props) do
        ~F"""
        <Filament.TagEngine.SlotProviderTest.Card>
          <:footer :if={props.empty_footer} />
          <:item><li><:title /></li></:item>
        </Filament.TagEngine.SlotProviderTest.Card>
        """
      end
    end
  end

  describe "slots, as in HEEx" do
    defp render_page(props) do
      title = %Entry{render_fn: fn -> {:text, "page title"} end}
      Page |> Filament.Test.mount!(Map.put(props, :title, [title])) |> Filament.Test.render_text()
    end

    test "a render site in an entry's content renders the slot of the template's own component" do
      assert render_page(%{}) =~ "page title"
    end

    test "a slot's declared default renders when no entry is given" do
      assert render_page(%{}) =~ "fallback"
    end

    test "a self-closing entry inside a component tag is an entry with no content" do
      text = render_page(%{empty_footer: true})
      assert text =~ "footers=1 children=false"
      refute text =~ "fallback"
    end
  end

  defp compile(source, env \\ __ENV__) do
    TagEngine.compile(source,
      caller: env,
      file: env.file,
      line: env.line,
      indentation: 0,
      tag_handler: Filament.HTMLEngine
    )
  end

  defp eval(ast, bindings \\ []) do
    context = %Filament.RenderContext{fiber_id: "root", fiber_tree: %{}, props: Keyword.get(bindings, :props, %{})}
    Process.put(:filament_render_context, context)

    try do
      {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
      result
    after
      Process.delete(:filament_render_context)
    end
  end

  describe "<:slot_name /> — provider render site" do
    test "emits {:slot, name, entries, nil} with entries from assigns" do
      ast = compile("<:header />")

      entry = %Entry{render_fn: fn -> {:text, "hi"} end}
      result = eval(ast, props: %{header: [entry]})
      assert {:slot, :header, [^entry], nil} = result
    end

    test "emits empty entries list when slot is absent from assigns" do
      ast = compile("<:body />")
      assert {:slot, :body, [], nil} = eval(ast)
    end

    test "default: attr sets the fallback module" do
      ast = compile("<:footer default={String} />")
      assert {:slot, :footer, [], String} = eval(ast)
    end

    test "default: attr is nil when not specified" do
      ast = compile("<:header />")
      assert {:slot, :header, [], nil} = eval(ast)
    end

    test "slot name is atomised from the template tag" do
      ast = compile("<:body_content />")
      {:slot, name, [], nil} = eval(ast)
      assert name == :body_content
    end
  end

  describe "VNode.validate!" do
    test "accepts the :slot vnode form" do
      entry = %Entry{render_fn: fn -> {:text, "x"} end}
      assert {:slot, :header, [^entry], nil} = Filament.VNode.validate!({:slot, :header, [entry], nil})
    end

    test "accepts :slot with a default module" do
      assert {:slot, :footer, [], String} = Filament.VNode.validate!({:slot, :footer, [], String})
    end
  end
end
