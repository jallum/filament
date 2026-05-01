defmodule Filament.SigilFPhase2Test do
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Filament.SigilF

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

      assert %Phoenix.LiveView.Rendered{} = result
      dynamic_result = result.dynamic.(false)
      assert is_list(dynamic_result)
      
      comprehension = Enum.find(dynamic_result, fn 
        %Phoenix.LiveView.Comprehension{} -> true
        _ -> false
      end)
      
      assert %Phoenix.LiveView.Comprehension{} = comprehension
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

      assert %Phoenix.LiveView.Rendered{} = result
      iodata = Phoenix.HTML.Safe.to_iodata(result)
      html = IO.iodata_to_binary(iodata)
      assert html =~ "key="
      assert html =~ "Item 1"
    end

    test ":for comprehension with dynamic content" do
      assigns = %{items: [1, 2, 3]}
      
      result = ~F"""
      <ul>
        <li :for={item <- @items}>
          Item: {@item}
        </li>
      </ul>
      """

      assert %Phoenix.LiveView.Rendered{} = result
      dynamic_result = result.dynamic.(false)
      
      assert [%Phoenix.LiveView.Comprehension{} = comprehension] = dynamic_result
      assert length(comprehension.entries) == 3
    end
  end

  describe "~F sigil Phase 2: Known limitations" do
    @tag :skip  # TODO: Future enhancement for compile-time key validation
    test "component in :for without explicit key tracking" do
      flunk("Compile-time component key validation is a TODO for future enhancement")
    end
  end
end
