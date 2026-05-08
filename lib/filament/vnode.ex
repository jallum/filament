defmodule Filament.VNode do
  @moduledoc false

  defmodule Error do
    @moduledoc "Exception raised when VNode validation fails"
    defexception message: nil
  end

  @type t ::
          {:text, iodata()}
          | {:element, binary(), [{binary(), term()}], [t()]}
          | {:component, module(), map(), term() | nil}
          | {:fragment, [t()]}

  @doc """
  Validates a VNode tree recursively.

  Raises %Filament.VNode.Error{} if the tree contains an unrecognised node shape.
  Returns the vnode unchanged if valid.

  ## Examples

      iex> vnode = {:text, "hello"}
      iex> Filament.VNode.validate!(vnode)
      {:text, "hello"}
  """
  def validate!(vnode) do
    validate_node!(vnode)
    vnode
  end

  # Private validation functions

  defp validate_node!({:text, _content}), do: :ok

  defp validate_node!({:element, _tag, _attrs, children}) do
    Enum.each(children, &validate_node!/1)
  end

  defp validate_node!({:component, _module, _props, _key}), do: :ok

  defp validate_node!({:fragment, children}) do
    Enum.each(children, &validate_node!/1)
  end

  defp validate_node!(invalid) do
    raise Error, message: "invalid vnode: #{inspect(invalid)}"
  end
end
