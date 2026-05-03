defmodule Filament.SigilFPhase2Test do
  use ExUnit.Case, async: true

  import Filament.SigilF

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Comprehension
  alias Phoenix.LiveView.Rendered

  describe "~F sigil Phase 2: :for comprehension" do
    test ":for comprehension produces Comprehension struct with items" do
      assigns = %{items: [%{id: 1, name: "Item 1"}, %{id: 2, name: "Item 2"}]}

      result = ~F"""
      <ul>
        <li :for={item <- @items}>
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
      assigns = %{items: [%{id: 1, name: "Item 1"}]}

      result = ~F"""
      <ul>
        <li :for={item <- @items} key={item.id}>
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
      assigns = %{items: [1, 2, 3]}

      result = ~F"""
      <ul>
        <li :for={item_value <- @items}>
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

  describe "~F sigil Phase 2: Known limitations" do
    # TODO: Future enhancement for compile-time key validation
    @tag :skip
    test "component in :for without explicit key tracking" do
      flunk("Compile-time component key validation is a TODO for future enhancement")
    end
  end
end
