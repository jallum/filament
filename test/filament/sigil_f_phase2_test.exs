defmodule Filament.SigilFPhase2Test do
  use ExUnit.Case, async: true

  import Filament.SigilF

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Comprehension
  alias Phoenix.LiveView.Rendered

  describe "~F sigil Phase 2: :for comprehension" do
    test ":for comprehension produces Comprehension struct with items" do
      items = [%{id: 1, name: "Item 1"}, %{id: 2, name: "Item 2"}]

      result = ~F"""
      <ul>
        <li :for={item <- items}>
          {item.name}
        </li>
      </ul>
      """

      assert %Rendered{} = result
      dynamic_result = result.dynamic.(false)
      assert is_list(dynamic_result)

      comprehension =
        Enum.find(dynamic_result, fn
          %Comprehension{} -> true
          _ -> false
        end)

      assert %Comprehension{} = comprehension
      assert length(comprehension.entries) == 2
    end

    test ":for comprehension renders correctly with key attribute" do
      items = [%{id: 1, name: "Item 1"}]

      result = ~F"""
      <ul>
        <li :for={item <- items} key={item.id}>
          {item.name}
        </li>
      </ul>
      """

      assert %Rendered{} = result
      iodata = Safe.to_iodata(result)
      html = IO.iodata_to_binary(iodata)
      assert html =~ "key="
      assert html =~ "Item 1"
    end

    test ":for comprehension with dynamic content" do
      items = [1, 2, 3]

      result = ~F"""
      <ul>
        <li :for={item_value <- items}>
          Item: {item_value}
        </li>
      </ul>
      """

      assert %Rendered{} = result
      dynamic_result = result.dynamic.(false)

      assert [%Comprehension{} = comprehension] = dynamic_result
      assert length(comprehension.entries) == 3
    end
  end

  describe "~F sigil Phase 2: JSX {for} block syntax" do
    test "{for x <- list do}…{end} produces Comprehension struct" do
      items = ["alpha", "beta", "gamma"]

      result = ~F"""
      <ul>
        {for item <- items do}
          <li>{item}</li>
        {end}
      </ul>
      """

      assert %Rendered{} = result
      dynamic_result = result.dynamic.(false)

      comprehension =
        Enum.find(dynamic_result, fn
          %Comprehension{} -> true
          _ -> false
        end)

      assert %Comprehension{} = comprehension
      assert length(comprehension.entries) == 3
    end

    test "{for} block renders correct HTML for each item" do
      items = ["alpha", "beta"]

      result = ~F"""
      <ul>
        {for item <- items do}
          <li>{item}</li>
        {end}
      </ul>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "alpha"
      assert html =~ "beta"
    end
  end

  describe "~F sigil Phase 2: JSX {if} block syntax" do
    test "{if cond do}…{end} renders then branch when true" do
      show = true

      result = ~F"""
      <div>
        {if show do}
          <span>visible</span>
        {end}
      </div>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "visible"
    end

    test "{if cond do}…{end} renders nothing when false" do
      show = false

      result = ~F"""
      <div>
        {if show do}
          <span>visible</span>
        {end}
      </div>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      refute html =~ "visible"
    end

    test "{if cond do}…{else}…{end} renders correct branch" do
      locked = true

      result = ~F"""
      <div>
        {if locked do}
          <span>locked</span>
        {else}
          <span>open</span>
        {end}
      </div>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "locked"
      refute html =~ "open"
    end

    test "{if cond do}…{else}…{end} renders else branch when false" do
      locked = false

      result = ~F"""
      <div>
        {if locked do}
          <span>locked</span>
        {else}
          <span>open</span>
        {end}
      </div>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      refute html =~ "locked"
      assert html =~ "open"
    end

    test "nested {if} blocks work correctly" do
      a = true
      b = false

      result = ~F"""
      <div>
        {if a do}
          {if b do}
            <span>both</span>
          {else}
            <span>only-a</span>
          {end}
        {end}
      </div>
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "only-a"
      refute html =~ "both"
    end
  end

  describe "~F sigil: {case} block syntax" do
    test "matches tuple patterns and renders the selected branch" do
      for {primary, expected} <- [
            {{:scan, "Scan item"}, "<button>Scan item</button>"},
            {{:review, "Review item"}, "<a href=\"/reviews\">Review item</a>"},
            {:other, "<span>unknown</span>"}
          ] do
        result = ~F"""
        {case primary do}
          {{:scan, label} ->}
            <button>{label}</button>
          {{:review, label} ->}
            <a href="/reviews">{label}</a>
          {_ ->}
            <span>unknown</span>
        {end}
        """

        html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
        assert html =~ expected
      end
    end

    test "supports guards and nested blocks" do
      primary = {:review, 3}

      result = ~F"""
      {case primary do}
        {{:review, count} when count > 0 ->}
          {if count > 1 do}
            <span>{count} reviews</span>
          {end}
        {_ ->}
          <span>none</span>
      {end}
      """

      html = result |> Safe.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "3 reviews"
      refute html =~ "none"
    end

    test "requires a clause" do
      source = "import Filament.SigilF\n~F\"{case value do}{end}\""

      assert_raise Phoenix.LiveView.TagEngine.Tokenizer.ParseError,
                   ~r/requires at least one clause/,
                   fn -> Code.eval_string(source, value: :anything, file: __ENV__.file) end
    end
  end

  describe "~F sigil Phase 2: Known limitations" do
    @tag :skip
    test "component in :for without explicit key tracking" do
      flunk("Compile-time component key validation is a TODO for future enhancement")
    end
  end
end
