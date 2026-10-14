defmodule Filament.Template do
  @moduledoc false

  # Plans are compile-time literals. Only bindings and child renders are rebuilt.
  defstruct [:static, :bindings, :fingerprint, :vnode, :values]

  def web_target? do
    case Process.get(:filament_render_context) do
      %Filament.RenderContext{target: Filament.Web} -> true
      _ -> false
    end
  end

  def bind(plan, values), do: %{plan | values: values}

  def walk(%__MODULE__{} = plan, context) do
    values =
      Enum.zip_with(plan.bindings, plan.values, fn
        {kind, _key}, value when kind in [:child, :components] ->
          Filament.Renderer.walk_value(value, context)

        {{:rows, _keyed?}, _key}, rows ->
          Enum.map(rows, fn {key, row} -> {key, walk(row, context)} end)

        _, value ->
          value
      end)

    %{plan | values: values}
  end
end
