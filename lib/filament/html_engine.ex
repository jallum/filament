defmodule Filament.HTMLEngine do
  @moduledoc false

  @behaviour Filament.TagEngine

  alias Phoenix.HTML.Engine

  @impl true
  def classify_type(":inner_block"), do: {:error, "the slot name :inner_block is reserved"}
  def classify_type(":" <> name), do: {:slot, name}

  def classify_type(<<first, _::binary>> = name) when first in ?A..?Z, do: {:remote_component, name}

  def classify_type("."), do: {:error, "a component name is required after ."}
  def classify_type("." <> name), do: {:local_component, name}
  def classify_type(name), do: {:tag, name}

  @impl true
  for void <- ~w(area base br col hr img input link meta param command keygen source) do
    def void?(unquote(void)), do: true
  end

  def void?(_), do: false

  def class_attribute_encode(list) when is_list(list), do: list |> class_attribute_list() |> Engine.encode_to_iodata!()

  def class_attribute_encode(other), do: empty_attribute_encode(other)

  defp class_attribute_list(list), do: class_attribute_list(list, [])

  defp class_attribute_list([], acc), do: acc
  defp class_attribute_list([nil | t], acc), do: class_attribute_list(t, acc)
  defp class_attribute_list([false | t], acc), do: class_attribute_list(t, acc)

  defp class_attribute_list([h | t], acc) when is_list(h) do
    class_attribute_list(t, class_attribute_list(h, acc))
  end

  defp class_attribute_list([h | t], []), do: class_attribute_list(t, [to_string(h)])
  defp class_attribute_list([h | t], acc), do: class_attribute_list(t, [acc, " ", to_string(h)])

  @doc false
  def empty_attribute_encode(nil), do: ""
  def empty_attribute_encode(false), do: ""
  def empty_attribute_encode(true), do: ""
  def empty_attribute_encode(value), do: Engine.encode_to_iodata!(value)
end
