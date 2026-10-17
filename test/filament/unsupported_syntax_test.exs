defmodule Filament.UnsupportedSyntaxTest do
  @moduledoc """
  HEEx syntax `~F` has no meaning for is rejected, not reinterpreted.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.TagEngine.Tokenizer.ParseError

  defmodule Spread do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_props), do: ~F|<div {[on_key: fn _key, _mods -> :ok end]}>x</div>|
    end
  end

  defp compile(template) do
    Code.eval_string(~s|import Filament.SigilF\n~F"""\n#{template}\n"""|, [], file: __ENV__.file)
  end

  test "a local function component" do
    assert_raise ParseError, ~r/local function components \(`<\.foo>`\) are not supported/, fn ->
      compile("<div><.foo depth={1} /></div>")
    end
  end

  test ":let on a component" do
    assert_raise CompileError, ~r/:let is not supported/, fn -> compile("<Mod :let={x}>{x}</Mod>") end
  end

  for attr <- [":key={1}", ":let={x}", ~s(:bogus="y")] do
    test "#{attr} on a slot entry" do
      assert_raise ParseError, ~r/is not supported on slot entries/, fn ->
        compile("<Mod><:col #{unquote(attr)}>c</:col></Mod>")
      end
    end
  end

  test "a self-closing macro component" do
    assert_raise ParseError, ~r/needs a closing tag/, fn ->
      compile(~s(<script :type={Phoenix.LiveView.ColocatedHook} name=".h" />))
    end
  end

  test "an id beside on_key" do
    assert_raise ParseError, ~r/id can't be set on an element with on_key/, fn ->
      compile(~s(<div id="mine" on_key={fn _, _ -> :ok end}>x</div>))
    end
  end

  test "on_key in an attribute spread" do
    assert_raise ArgumentError, ~r/on_key must be written on the element/, fn ->
      Filament.Reconciler.mount(Spread, %{}, target: Filament.Web)
    end
  end
end
