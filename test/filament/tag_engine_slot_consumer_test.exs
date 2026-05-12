defmodule Filament.TagEngine.SlotConsumerTest do
  @moduledoc """
  opi-lzr.2: Consumer-side slot syntax.

  Verifies that `<MyComp><:slot>content</:slot></MyComp>` compiles to a
  `{:component, Mod, assigns, nil}` vnode where `assigns.slot_name` is a
  list of `%Filament.Slot.Entry{}` structs whose `render_fn/0` returns the
  compiled inner vnode.
  """
  use ExUnit.Case, async: true

  alias Filament.Slot.Entry
  alias Filament.TagEngine

  # A target component declared with slots so unknown-slot compile checks have
  # something to validate against.
  defmodule Layout do
    @moduledoc false
    use Filament.Component

    defcomponent Layout do
      slot :header, required: false
      slot :body, required: true
      slot :footer, required: false, default: String

      def render(_), do: nil
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
    {result, _} = Code.eval_quoted(ast, bindings, __ENV__)
    result
  end

  describe "component with slot content" do
    test "single slot compiles to :component vnode with slot entry in assigns" do
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>
          <:body><span>hello</span></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      {:component, Filament.TagEngine.SlotConsumerTest.Layout.Layout, assigns, nil} = eval(ast)
      assert [%Entry{render_fn: render_fn}] = assigns.body
      assert {:element, "span", _, [{:text, "hello"}]} = render_fn.()
    end

    test "multiple slots accumulate as separate keys in assigns" do
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>
          <:header><span>Header</span></:header>
          <:body><div>Body</div></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      {:component, Filament.TagEngine.SlotConsumerTest.Layout.Layout, assigns, nil} = eval(ast)
      assert [%Entry{}] = assigns.header
      assert [%Entry{}] = assigns.body
    end

    test "slot render_fn captures caller assigns via closure" do
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>
          <:body><span>{title}</span></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      {:component, _, assigns, nil} = eval(ast, title: "Dynamic")
      [%Entry{render_fn: render_fn}] = assigns.body
      # render_fn captures 'title' from the call-site bindings
      assert {:element, "span", [], ["Dynamic"]} = render_fn.()
    end

    test "slot with attrs carries them in the entry" do
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>
          <:body label="main"><div>Body</div></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      {:component, _, assigns, nil} = eval(ast)
      assert [%Entry{attrs: %{label: "main"}}] = assigns.body
    end

    test "whitespace between slot tags is silently ignored" do
      # This should compile without error even though there is whitespace text
      # at the component's top level.
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>

          <:body><span>ok</span></:body>

        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      assert {:component, _, %{body: [%Entry{}]}, nil} = eval(ast)
    end

    test "non-whitespace bare content inside component raises CompileError" do
      assert_raise Phoenix.LiveView.Tokenizer.ParseError, ~r/unexpected content inside component/, fn ->
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout>
          bare text
          <:body><span>ok</span></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)
      end
    end

    test "regular props on the component tag are preserved alongside slot assigns" do
      ast =
        compile("""
        <Filament.TagEngine.SlotConsumerTest.Layout.Layout id="root">
          <:body><span>Body</span></:body>
        </Filament.TagEngine.SlotConsumerTest.Layout.Layout>
        """)

      {:component, _, assigns, nil} = eval(ast)
      assert assigns.id == "root"
      assert [%Entry{}] = assigns.body
    end
  end
end
