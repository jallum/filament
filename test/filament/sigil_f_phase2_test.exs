defmodule Filament.SigilFPhase2Test do
  use ExUnit.Case, async: true

  import Filament.SigilF

  describe "~F sigil Phase 2: :for comprehension" do
    test ":for comprehension renders one element per item" do
      items = [%{id: 1, name: "Item 1"}, %{id: 2, name: "Item 2"}]

      result = ~F"""
      <ul>
        <li :for={item <- items}>
          {item.name}
        </li>
      </ul>
      """

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "Item 1"
      assert html =~ "Item 2"
    end

    test ":for + key attribute survives into output" do
      items = [%{id: 1, name: "Item 1"}]

      result = ~F"""
      <ul>
        <li :for={item <- items} key={item.id}>
          {item.name}
        </li>
      </ul>
      """

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "Item: 1"
      assert html =~ "Item: 2"
      assert html =~ "Item: 3"
    end
  end

  describe "~F sigil Phase 2: JSX {for} block syntax" do
    test "{for} block renders correct HTML for each item" do
      items = ["alpha", "beta"]

      result = ~F"""
      <ul>
        {for item <- items do}
          <li>{item}</li>
        {end}
      </ul>
      """

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
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

      html = result |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html =~ "only-a"
      refute html =~ "both"
    end
  end
end
