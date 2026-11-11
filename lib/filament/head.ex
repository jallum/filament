defmodule Filament.Head do
  @moduledoc false
  # What a tree's `Filament.Hooks.use_head/1` calls declare of the
  # document's head: its title, canonical URL and meta tags, the deepest
  # declaration of each, and the last of siblings, winning.

  @type t :: %{title: String.t() | nil, canonical: String.t() | nil, meta: %{String.t() => String.t()}}

  @empty %{title: nil, canonical: nil, meta: %{}}

  @doc "A declaration from `use_head/1`'s options, its `nil`s dropped."
  @spec declaration!(keyword()) :: map()
  def declaration!(opts) do
    Enum.reduce(opts, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc when key in [:title, :canonical] and is_binary(value) -> Map.put(acc, key, value)
      {:meta, meta}, acc when is_list(meta) or is_map(meta) -> Map.put(acc, :meta, meta!(meta))
      other, _acc -> raise ArgumentError, "use_head/1 takes title:, canonical: and meta:, got: #{inspect(other)}"
    end)
  end

  defp meta!(meta) do
    for {name, content} <- meta, content != nil, into: %{} do
      if (is_atom(name) or is_binary(name)) and is_binary(content),
        do: {to_string(name), content},
        else: raise(ArgumentError, "use_head/1's meta: takes names and strings, got: #{inspect({name, content})}")
    end
  end

  @doc """
  A fiber's own declarations, from its `hook_slots`, in call order: where
  a render that only walks its stored output again starts its subtree's.
  """
  @spec own(map()) :: map() | nil
  def own(hook_slots) do
    hook_slots
    |> Enum.filter(&match?({_index, {:head, _}}, &1))
    |> Enum.sort()
    |> Enum.reduce(nil, fn {_index, {:head, declaration}}, head -> merge(head, declaration) end)
  end

  @doc "The head `tree` declares, the deepest declaration of each winning."
  @spec collect(map()) :: t()
  def collect(%{"root" => %{head: head}}), do: merge(@empty, head)
  def collect(_tree), do: @empty

  @doc """
  `declaration` over `head`: its title and canonical URL replace the ones
  there, its meta tags are added by name. Either may be `nil`, none.
  """
  @spec merge(map() | nil, map() | nil) :: map() | nil
  def merge(head, nil), do: head
  def merge(nil, declaration), do: declaration

  def merge(head, declaration) do
    Enum.reduce(declaration, head, fn
      {:meta, meta}, head -> Map.update(head, :meta, meta, &Map.merge(&1, meta))
      {key, value}, head -> Map.put(head, key, value)
    end)
  end

  @doc """
  The tags of `head` but its title, each `{tag, attributes}`: Open Graph's
  `og:` meta by `property`, others by `name`.
  """
  @spec tags(t() | nil) :: [{String.t(), [{String.t(), String.t()}]}]
  def tags(nil), do: []

  def tags(head) do
    canonical = if head.canonical, do: [{"link", [{"rel", "canonical"}, {"href", head.canonical}]}], else: []
    meta = for {name, content} <- Enum.sort(head.meta), do: {"meta", [{meta_key(name), name}, {"content", content}]}
    canonical ++ meta
  end

  defp meta_key("og:" <> _), do: "property"
  defp meta_key(_name), do: "name"
end
