defmodule Filament.SigilFAttributeTest do
  @moduledoc """
  `@name` in `~F` is the module attribute, as anywhere in Elixir.
  """
  use ExUnit.Case, async: true

  defmodule Picker do
    @moduledoc false
    use Filament.Component

    defcomponent do
      prop(:label, :string, required: true)

      @pick "pick rounded"
      @sizes ~w(s m l)

      def render(%{label: label}) do
        ~F"""
        <div class={@pick}>{label} <i :for={size <- @sizes}>{size}</i> {@pick}</div>
        """
      end
    end
  end

  test "reads module attributes in text, attribute values and loops" do
    for target <- [Filament.VNode, Filament.Web] do
      {tree, output, _} = Filament.Reconciler.mount(Picker, %{label: "x"}, target: target)
      html = output |> Filament.Web.to_iodata() |> IO.iodata_to_binary()
      assert html == ~s(<div class="pick rounded">x <i>s</i><i>m</i><i>l</i> pick rounded</div>)
      Filament.Reconciler.unmount(tree)
    end
  end

  test "an attribute the module doesn't have fails to compile, naming the prop to read" do
    source = """
    defmodule Filament.SigilFAttributeTest.Pasted do
      use Filament.Component

      defcomponent do
        prop(:name, :string)
        def render(assigns), do: ~F"<h1>{@name}</h1>"
      end
    end
    """

    assert_raise CompileError, ~r/@name is a module attribute in ~F.*has none; read a prop as props.name/, fn ->
      Code.compile_string(source, "pasted.ex")
    end
  end
end
