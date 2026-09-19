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

  describe "<:slot_name /> — provider render site" do
    test "emits {:slot, name, entries, nil} with entries from assigns" do
      ast = compile("<:header />")

      entry = %Entry{render_fn: fn -> {:text, "hi"} end}
      result = eval(ast, assigns: %{header: [entry]})
      assert {:slot, :header, [^entry], nil} = result
    end

    test "emits empty entries list when slot is absent from assigns" do
      ast = compile("<:body />")
      assert {:slot, :body, [], nil} = eval(ast, assigns: %{})
    end

    test "default: attr sets the fallback module" do
      ast = compile("<:footer default={String} />")
      assert {:slot, :footer, [], String} = eval(ast, assigns: %{})
    end

    test "default: attr is nil when not specified" do
      ast = compile("<:header />")
      assert {:slot, :header, [], nil} = eval(ast, assigns: %{})
    end

    test "slot name is atomised from the template tag" do
      ast = compile("<:body_content />")
      {:slot, name, [], nil} = eval(ast, assigns: %{})
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
