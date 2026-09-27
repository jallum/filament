defmodule Filament.BooleanAttributeTest do
  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe

  defmodule Input do
    @moduledoc false
    use Filament.Component

    def render(%{mode: :bare}), do: ~F"<input disabled>"
    def render(%{mode: :dynamic, value: value}), do: ~F"<input disabled={value} id={nil} class={nil}>"
    def render(%{mode: :spread, attrs: attrs}), do: ~F"<input {attrs}>"
  end

  test "bare true, dynamic false/nil, and spread attributes agree on both rendering paths" do
    cases = [
      {%{mode: :bare}, "<input disabled>"},
      {%{mode: :dynamic, value: true}, "<input disabled>"},
      {%{mode: :dynamic, value: false}, "<input>"},
      {%{mode: :dynamic, value: nil}, "<input>"},
      {%{mode: :spread, attrs: [disabled: nil, id: nil, class: nil, checked: false]}, "<input>"},
      {%{mode: :spread, attrs: [disabled: true]}, "<input disabled>"}
    ]

    for {props, expected} <- cases do
      {_, walked, _} = Filament.Reconciler.mount(Input, props)
      assert walked |> Filament.Web.to_iodata() |> IO.iodata_to_binary() == expected
      assert walked |> Filament.Web.to_rendered() |> Safe.to_iodata() |> IO.iodata_to_binary() == expected
    end
  end
end
