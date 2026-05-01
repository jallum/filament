defmodule Filament.VNode do
  @moduledoc """
  VNode IR types for Filament component rendering.
  
  VNodes are tagged tuples that serve as the intermediate representation
  returned by component render functions. They are pattern-matched heavily
  during the render walk for performance.
  
  Five variants:
  - :text - text node
  - :element - HTML element
  - :component - child component reference
  - :fragment - transparent grouping
  - :keyed_list - explicitly keyed list
  """

  defmodule Error do
    @moduledoc "Exception raised when VNode validation fails"
    defexception message: nil
  end

  @type t ::
          {:text, iodata()}
          | {:element, binary(), [{binary(), term()}], [t()]}
          | {:component, module(), map(), term() | nil}
          | {:fragment, [t()]}
          | {:keyed_list, [{term(), t()}]}

  @doc """
  Validates a VNode tree recursively.
  
  Raises %Filament.VNode.Error{} if:
  1. A :keyed_list contains duplicate keys
  2. A :keyed_list item's vnode is itself a :keyed_list (no nested keyed lists)
  3. A :component vnode inside a :keyed_list has key: nil
  
  Returns the vnode unchanged if valid.
  
  ## Examples
  
      iex> vnode = {:text, "hello"}
      iex> Filament.VNode.validate!(vnode)
      {:text, "hello"}
  """
  def validate!(vnode) do
    validate_node!(vnode, false)
    vnode
  end

  # Private validation functions
  
  defp validate_node!({:text, _content}, _in_keyed_list?), do: :ok
  
  defp validate_node!({:element, _tag, _attrs, children}, in_keyed_list?) do
    Enum.each(children, &validate_node!(&1, in_keyed_list?))
  end
  
  defp validate_node!({:component, module, _props, key}, true = _in_keyed_list?) when is_nil(key) do
    raise Error, message: "component #{inspect(module)} inside keyed_list must have a non-nil key"
  end
  
  defp validate_node!({:component, _module, _props, _key}, _in_keyed_list?), do: :ok
  
  defp validate_node!({:fragment, children}, in_keyed_list?) do
    Enum.each(children, &validate_node!(&1, in_keyed_list?))
  end
  
  defp validate_node!({:keyed_list, items}, _in_keyed_list?) do
    # Check for nested :keyed_list
    Enum.each(items, fn {key, vnode} ->
      if match?({:keyed_list, _}, vnode) do
        raise Error, message: "nested keyed_list with key #{inspect key} is not allowed"
      end
      validate_node!(vnode, true)
    end)
    
    # Check for duplicate keys
    keys = Enum.map(items, fn {key, _vnode} -> key end)
    unique_keys = Enum.uniq(keys)
    
    if length(keys) != length(unique_keys) do
      duplicate_keys = keys -- unique_keys
      raise Error, message: "duplicate key #{inspect(hd(duplicate_keys))} in keyed list"
    end
    
    :ok
  end
  
  defp validate_node!(invalid, _in_keyed_list?) do
    raise Error, message: "invalid vnode: #{inspect invalid}"
  end
end
