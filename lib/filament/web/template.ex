defmodule Filament.Web.Template do
  @moduledoc false

  alias Filament.Template
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Comprehension
  alias Phoenix.LiveView.Rendered

  def to_rendered(%Template{} = template) do
    if Template.normal_attributes?(template) do
      bindings = prepare(template)

      %Rendered{
        static: template.static,
        fingerprint: template.fingerprint,
        dynamic: fn _track -> Enum.map(bindings, &encode/1) end,
        root: Filament.Web.root?(template.vnode),
        caller: :not_available
      }
    else
      template |> Template.materialize() |> Filament.Web.to_rendered()
    end
  end

  defp prepare(template), do: Enum.zip_with(template.bindings, template.values, &prepare_binding/2)

  defp prepare_binding({kind, key}, value) do
    cond do
      kind == :components ->
        {key, collection(value), :opaque}

      kind == :child and (is_struct(value, Template) or is_struct(value, Rendered)) ->
        {key, Filament.Web.to_rendered(value), :opaque}

      scalar?(value) ->
        {key, value, kind}

      true ->
        encoded = encode({key, value, kind})
        mode = if is_struct(encoded, Rendered) or is_struct(encoded, Comprehension), do: :opaque, else: :encoded
        {key, encoded, mode}
    end
  end

  # Only built-in scalar encoders are pure. Custom Safe implementations and
  # other opaque bindings are evaluated on every render, before comparison.
  defp scalar?(value), do: is_binary(value) or is_number(value) or is_atom(value)

  defp encode({_key, value, mode}) when mode in [:encoded, :opaque], do: value
  defp encode({_key, value, {:attribute, name}}), do: Filament.Web.attribute_value(name, value)
  defp encode({_key, value, :child}) when value in [nil, false], do: []
  defp encode({_key, value, :child}) when is_tuple(value) or is_list(value), do: Filament.Web.to_rendered(value)
  defp encode({_key, value, :child}), do: Safe.to_iodata(value)

  defp collection([]), do: Filament.Web.to_rendered({:fragment, []})

  defp collection(children) do
    if homogeneous_keyed_templates?(children) do
      [{:component, _, _, _, first} | _] = children
      entries = Enum.map(children, &entry/1)
      # LiveView tells a comprehension from a template only by fingerprint.
      fingerprint = Filament.Web.fingerprint({:comprehension, first.fingerprint})
      %Comprehension{static: first.static, fingerprint: fingerprint, has_key?: true, entries: entries}
    else
      Filament.Web.to_rendered({:fragment, children})
    end
  end

  defp homogeneous_keyed_templates?([{:component, _, _, _, %Template{} = first} | _] = children) do
    keys =
      Enum.map(children, fn
        {:component, mod, _props, key, %Template{} = output} when key not in [nil, false] ->
          if output.static == first.static and output.bindings == first.bindings and Template.normal_attributes?(output),
            do: {mod, key}

        _ ->
          nil
      end)

    not Enum.member?(keys, nil) and MapSet.size(MapSet.new(keys)) == length(keys)
  end

  defp homogeneous_keyed_templates?(_), do: false

  defp entry({:component, mod, _props, key, template}) do
    bindings = prepare(template)
    variables = Map.new(for {key, value, mode} <- bindings, mode != :opaque, do: {key, {mode, value}})

    {{mod, key}, variables, fn changed, track? -> changed_bindings(bindings, changed, track?) end}
  end

  defp changed_bindings(bindings, changed, track?) do
    Enum.map(bindings, fn {key, _value, mode} = binding ->
      if mode == :opaque or not track? or Map.has_key?(changed, key), do: encode(binding)
    end)
  end
end
