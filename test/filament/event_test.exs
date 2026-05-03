defmodule Filament.EventTest do
  use ExUnit.Case, async: true

  alias Filament.TestEvents.TestPurchased

  # --- Tests ---

  test "1. struct enforcement — missing required field raises at runtime" do
    # struct! raises when required keys are missing at runtime
    assert_raise ArgumentError, fn ->
      struct!(TestPurchased, [])
    end

    assert_raise ArgumentError, fn ->
      struct!(TestPurchased, quantity: 5)
    end
  end

  test "2. defaults applied" do
    event = %TestPurchased{item_id: "abc"}
    assert event.item_id == "abc"
    assert event.quantity == 1
    assert event.note == nil
  end

  test "3. encode round-trip" do
    original = %TestPurchased{item_id: "xyz", quantity: 3, note: "hello"}
    {:ok, json} = TestPurchased.encode(original)
    assert {:ok, decoded} = TestPurchased.decode(json)
    assert decoded == original
  end

  test "4. decode from JSON string" do
    json = ~s|{"item_id":"abc","quantity":2}|
    assert {:ok, event} = TestPurchased.decode(json)
    assert event.item_id == "abc"
    assert event.quantity == 2
    assert event.note == nil
  end

  test "5. decode missing required field" do
    json = ~s|{"quantity":1}|
    assert {:error, {:missing_field, :item_id}} = TestPurchased.decode(json)
  end

  test "6. decode unknown fields ignored" do
    json = ~s|{"item_id":"x","extra":"junk","quantity":5}|
    assert {:ok, event} = TestPurchased.decode(json)
    assert event.item_id == "x"
    assert event.quantity == 5
  end

  test "7. decode type mismatch" do
    json = ~s|{"item_id":123,"quantity":1}|
    assert {:error, {:type_mismatch, [expected: :string, got: 123]}} = TestPurchased.decode(json)
  end

  test "8. decode optional missing — defaults applied" do
    json = ~s|{"item_id":"x"}|
    assert {:ok, event} = TestPurchased.decode(json)
    assert event.item_id == "x"
    assert event.quantity == 1
    assert event.note == nil
  end

  test "9. module namespaced under calling module" do
    assert Code.ensure_loaded?(TestPurchased)
    assert function_exported?(TestPurchased, :encode, 1)
    assert function_exported?(TestPurchased, :decode, 1)
  end

  test "10. compile error on unsupported type" do
    code = """
    defmodule BadType do
      import Filament.Event
      defevent BadEvent do
        field :a, :uuid
      end
    end
    """

    assert_raise CompileError, ~r/unsupported type :uuid/, fn ->
      Code.eval_string(code, [], file: "test_event_compile.exs")
    end
  end

  test "11. compile error on required + default" do
    code = """
    defmodule BadDefault do
      import Filament.Event
      defevent BadEvent do
        field :a, :string, required: true, default: "x"
      end
    end
    """

    assert_raise CompileError, ~r/mutually exclusive/, fn ->
      Code.eval_string(code, [], file: "test_event_compile2.exs")
    end
  end
end
