defmodule Filament.ColocatedHookTest do
  use ExUnit.Case, async: true

  describe "colocated hook support in ~F templates" do
    test "compiles without error when module uses Filament.Component" do
      # This is the failing case from the ticket:
      # <script :type={Phoenix.LiveView.ColocatedHook}> inside ~F raised
      # (ArgumentError) macro components are only supported in modules that `use Phoenix.Component`
      n = System.unique_integer([:positive])

      code = """
      defmodule ColocatedHookComp#{n} do
        use Filament.Component

        defcomponent do
          def render(%{}) do
            ~F\"\"\"
            <div>
              <span phx-hook=".MyHook" id="my-el"></span>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".MyHook">
                export default {
                  mounted() { console.log("mounted") }
                }
              </script>
            </div>
            \"\"\"
          end
        end
      end
      """

      assert [{_mod, _}] = Code.compile_string(code)
    end

    test "module with colocated hook defines __phoenix_macro_components__/0" do
      n = System.unique_integer([:positive])

      code = """
      defmodule ColocatedHookData#{n} do
        use Filament.Component

        defcomponent do
          def render(%{}) do
            ~F\"\"\"
            <span phx-hook=".DataHook" id="data-el"></span>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".DataHook">
              export default { mounted() {} }
            </script>
            \"\"\"
          end
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert function_exported?(mod, :__phoenix_macro_components__, 0)
      result = mod.__phoenix_macro_components__()
      assert is_map(result)
      assert Map.has_key?(result, Phoenix.LiveView.ColocatedHook)
    end

    test "module without colocated hook does not define __phoenix_macro_components__/0" do
      n = System.unique_integer([:positive])

      code = """
      defmodule NoHookComp#{n} do
        use Filament.Component

        defcomponent do
          def render(%{}) do
            ~F"<div>no hook here</div>"
          end
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      refute function_exported?(mod, :__phoenix_macro_components__, 0)
    end
  end
end
