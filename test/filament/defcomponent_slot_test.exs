defmodule Filament.DefcomponentSlotTest do
  use ExUnit.Case, async: true

  defmodule Fixtures do
    @moduledoc false
    use Filament.Component

    defcomponent WithRequiredSlot do
      slot :inner_block, required: true
      def render(_), do: nil
    end

    defcomponent WithOptionalSlot do
      slot :footer
      def render(_), do: nil
    end

    defcomponent WithDefaultSlot do
      slot :header, default: String
      def render(_), do: nil
    end

    defcomponent WithPropsAndSlots do
      prop :id, :string, required: true
      slot :inner_block, required: true
      slot :footer
      def render(_), do: nil
    end

    defcomponent NoSlots do
      prop :label, :string
      def render(_), do: nil
    end
  end

  describe "__slots__/0" do
    test "required slot has required: true and default: nil" do
      assert [%{name: :inner_block, required: true, default: nil}] =
               Fixtures.WithRequiredSlot.__slots__()
    end

    test "slot with no opts has required: false and default: nil" do
      assert [%{name: :footer, required: false, default: nil}] =
               Fixtures.WithOptionalSlot.__slots__()
    end

    test "default: module is preserved" do
      assert [%{name: :header, default: String}] = Fixtures.WithDefaultSlot.__slots__()
    end

    test "returns slots in declaration order" do
      [first, second] = Fixtures.WithPropsAndSlots.__slots__()
      assert first.name == :inner_block
      assert second.name == :footer
    end

    test "returns empty list when no slots declared" do
      assert [] = Fixtures.NoSlots.__slots__()
    end
  end

  describe "__validate_props__!/1 — slots" do
    test "raises when required slot is absent" do
      assert_raise ArgumentError, ~r/required slot :inner_block/, fn ->
        Fixtures.WithRequiredSlot.__validate_props__!(%{})
      end
    end

    test "raises when required slot is an empty list" do
      assert_raise ArgumentError, ~r/required slot :inner_block/, fn ->
        Fixtures.WithRequiredSlot.__validate_props__!(%{inner_block: []})
      end
    end

    test "accepts required slot when non-empty" do
      assert :ok = Fixtures.WithRequiredSlot.__validate_props__!(%{inner_block: [:entry]})
    end

    test "does not raise when optional slot is absent" do
      assert :ok = Fixtures.WithOptionalSlot.__validate_props__!(%{})
    end

    test "prop validation still applies alongside slot validation" do
      assert_raise ArgumentError, ~r/required prop :id/, fn ->
        Fixtures.WithPropsAndSlots.__validate_props__!(%{inner_block: [:entry]})
      end
    end
  end

  describe "compile-time collision check" do
    test "slot name that duplicates a prop name raises CompileError" do
      assert_raise CompileError, ~r/slot :title.*same name as a prop/, fn ->
        Code.compile_string("""
        defmodule CollisionFixture do
          use Filament.Component
          defcomponent Bad do
            prop :title, :string
            slot :title
            def render(_), do: nil
          end
        end
        """)
      end
    end
  end
end
