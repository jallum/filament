defmodule Filament.CondBlocksTest do
  use ExUnit.Case, async: true

  import Filament.SigilF

  alias Filament.Test, as: ComponentTest
  alias Phoenix.LiveView.TagEngine.Tokenizer.ParseError

  defmodule Counter do
    @moduledoc false
    use Filament.Component

    defcomponent do
      def render(_) do
        {count, set_count} = use_state(0)

        ~F"""
        {cond do}
          {count == 0 ->}<button on_click={fn -> set_count.(1) end}>start</button>
          {true ->}<button on_click={fn -> set_count.(0) end}>finish</button>
        {end}
        """
      end
    end
  end

  test "handlers and state updates select the new markup branch on each render" do
    view = ComponentTest.mount!(Counter, %{})
    assert ComponentTest.render_text(view) == "start"
    view = ComponentTest.click!(view, "button")
    assert ComponentTest.render_text(view) == "finish"
    view = ComponentTest.click!(view, "button")
    assert ComponentTest.render_text(view) == "start"
    ComponentTest.unmount(view)
  end

  test "inline clauses match the issue reproduction and preserve native cond order" do
    for {n, expected} <- [{2, "big"}, {1, "small"}] do
      result = ~F|<p>{cond do}{n > 1 -> "big"}{true -> "small"}{end}</p>|
      assert html(result) == "<p>#{expected}</p>"
    end
  end

  test "markup clauses support nested case, cond and for blocks" do
    items = Process.get(:cond_items, [1, 2])

    result = ~F"""
    {cond do}
      {items == [] ->}<p>empty</p>
      {true ->}
        {for n <- items do}
          {cond do}
            {n == 1 ->}<b>{n}</b>
            {true ->}{case n do}{2 -> "two"}{_ -> "other"}{end}
          {end}
        {end}
    {end}
    """

    assert html(result) =~ "<b>1</b>"
    assert html(result) =~ "two"
    refute html(result) =~ "empty"
  end

  test "unselected clause expressions are not evaluated" do
    selected = Process.get(:cond_selected, true)
    result = ~F|{cond do}{selected -> "yes"}{true -> send(self(), :wrong_branch)}{end}|
    assert html(result) == "yes"
    refute_received :wrong_branch
  end

  test "no matching clause retains native CondClauseError behavior" do
    selected = Process.get(:cond_selected, false)
    assert_raise CondClauseError, fn -> ~F|{cond do}{selected -> "no"}{end}| end
  end

  test "empty cond and clauses outside a block report template errors" do
    for {source, expected} <- [
          {"{cond do}{end}", ~r/requires at least one clause/},
          {"{true ->}{end}", ~r/clause without matching/}
        ] do
      assert_raise ParseError, expected, fn ->
        Code.eval_string("import Filament.SigilF\n~F|" <> source <> "|", [], file: __ENV__.file)
      end
    end
  end

  test "tags and slot entries stay within their block" do
    for {source, expected} <- [
          {"{if x do}<div>{end}</div>", ~r/<div> at line \d+ must be closed before \{end\} of its \{if\}/},
          {"<div>{if x do}</div>{end}", ~r/<\/div> closes a tag opened outside the \{if\}/},
          {"<p>{end}</p>", ~r/\{end\} without matching/},
          {"<Card>{if x do}<:header>H</:header>{end}</Card>", ~r/must be a direct child of its component/},
          {"<Card><div><:header>H</:header></div></Card>", ~r/must be a direct child of its component/}
        ] do
      assert_raise ParseError, expected, fn ->
        Code.eval_string("import Filament.SigilF\nx = true\n~F|" <> source <> "|", [], file: __ENV__.file)
      end
    end
  end

  defp html(rendered), do: rendered |> Filament.Web.to_iodata() |> IO.iodata_to_binary() |> String.trim()
end
