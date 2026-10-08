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

        _, value ->
          value
      end)

    %{plan | values: values}
  end

  def normal_attributes?(%__MODULE__{bindings: bindings, values: values}) do
    bindings
    |> Enum.zip_with(values, fn
      {{:attribute, name}, _key}, value ->
        value not in [nil, false, true] and not match?({:wire_ref, _}, value) and
          not Filament.Web.nested_attribute?(name, value)

      _, _ ->
        true
    end)
    |> Enum.all?()
  end

  def materialize(%__MODULE__{vnode: vnode, values: values}) do
    materialize(vnode, List.to_tuple(values))
  end

  defp materialize({:binding, index}, values), do: elem(values, index)

  defp materialize({:element, name, attrs, children}, values) do
    {:element, name, Enum.map(attrs, fn {name, value} -> {name, materialize(value, values)} end),
     materialize(children, values)}
  end

  defp materialize({:fragment, children}, values), do: {:fragment, materialize(children, values)}
  defp materialize(children, values) when is_list(children), do: Enum.map(children, &materialize(&1, values))
  defp materialize(value, _values), do: value
end
