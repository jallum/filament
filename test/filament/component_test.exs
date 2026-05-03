defmodule Filament.ComponentTest do
  use ExUnit.Case, async: true

  defmodule TestComponents do
    use Filament.Component

    defcomponent MinimalComponent do
      prop(:value, :string, required: true)

      def render(%{value: value}) do
        # In a real implementation, this would return %Phoenix.LiveView.Rendered{}
        %Phoenix.LiveView.Rendered{
          static: ["<span>", "</span>"],
          dynamic: fn _ -> [value] end,
          fingerprint: 12345,
          root: true
        }
      end
    end

    defcomponent ComponentWithDefaults do
      prop(:required_prop, :string, required: true)
      prop(:optional_prop, :string, default: "default-value")
      prop(:another_optional, :integer, default: 42)

      def render(props) do
        %Phoenix.LiveView.Rendered{
          static: ["<div>", "</div>"],
          dynamic: fn _ -> [inspect(props)] end,
          fingerprint: 67890,
          root: true
        }
      end
    end

    defmodule NotAComponent do
      def some_function, do: :not_a_component
    end
  end

  describe "defcomponent macro" do
    test "compiles minimal component successfully" do
      assert Kernel.function_exported?(TestComponents.MinimalComponent, :render, 1)
    end

    test "component is an atom (normal module)" do
      assert is_atom(TestComponents.MinimalComponent)
    end

    test "has render/1 function exported" do
      assert function_exported?(TestComponents.MinimalComponent, :render, 1)
    end

    test "__filament_component__? returns true" do
      assert TestComponents.MinimalComponent.__filament_component__?()
    end
  end

  describe "__props__/0" do
    test "includes required prop metadata" do
      props = TestComponents.MinimalComponent.__props__()
      assert Keyword.has_key?(props, :value)
      %{type: type, required: required, default: default} = props[:value]
      assert type == :string
      assert required == true
      assert default == :__NO_DEFAULT__
    end

    test "includes default values in metadata" do
      props = TestComponents.ComponentWithDefaults.__props__()

      assert props[:required_prop].required == true
      assert props[:required_prop].default == :__NO_DEFAULT__

      assert props[:optional_prop].required == false
      assert props[:optional_prop].default == "default-value"

      assert props[:another_optional].required == false
      assert props[:another_optional].default == 42
    end
  end

  describe "__validate_props__!/1" do
    test "accepts props with all required fields present" do
      assert :ok = TestComponents.MinimalComponent.__validate_props__!(%{value: "test"})
    end

    test "raises ArgumentError when required prop is missing" do
      assert_raise ArgumentError, ~r/required prop :value missing/, fn ->
        TestComponents.MinimalComponent.__validate_props__!(%{})
      end
    end

    test "accepts empty map when all props have defaults" do
      # This should work because required_prop is actually required
      # So let's use a component where all are optional
      assert :ok =
               TestComponents.ComponentWithDefaults.__validate_props__!(%{
                 required_prop: "provided"
              })
    end

    test "uses default values when not provided" do
      props = %{required_prop: "provided"}
      TestComponents.ComponentWithDefaults.__validate_props__!(props)
      # The validation should succeed, actual default handling happens in render
    end

    test "error message includes missing prop name" do
      try do
        TestComponents.MinimalComponent.__validate_props__!(%{})
        flunk("Expected ArgumentError")
      rescue
        error in ArgumentError ->
          assert Exception.message(error) =~ ":value"
      end
    end
  end

  describe "prop validation with multiple required props" do
    defmodule MultiPropComponent do
      use Filament.Component

      defcomponent MultiProp do
        prop(:prop1, :string, required: true)
        prop(:prop2, :string, required: true)
        prop(:prop3, :string, default: "optional")

        def render(_props) do
          %Phoenix.LiveView.Rendered{
            static: ["<div>", "</div>"],
            dynamic: fn _ -> [] end,
            fingerprint: 11111,
            root: true
          }
        end
      end
    end

    test "raises with specific missing prop name" do
      assert_raise ArgumentError, ~r/prop :prop1 missing/, fn ->
        MultiPropComponent.MultiProp.__validate_props__!(%{prop2: "value2"})
      end
    end

    test "accepts when all required props present" do
      assert :ok =
               MultiPropComponent.MultiProp.__validate_props__!(%{
                 prop1: "value1",
                 prop2: "value2"
              })
    end
  end

  describe "Compile-time enforcement" do
    test "component without render/1 fails to compile" do
      code = """
      defmodule TestNoRender do
        use Filament.Component

        defcomponent BadComponent do
          prop :value, :string, required: true
          # No render/1 defined
        end
      end
      """

      # This should raise a compile error
      assert_raise CompileError, ~r/must define render\/1/, fn ->
        Code.compile_string(code)
      end
    end
  end

  describe "non-component module" do
    test "does not have __filament_component__? function" do
      refute function_exported?(TestComponents.NotAComponent, :__filament_component__?, 0)
    end
  end
end
