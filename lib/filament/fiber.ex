defmodule Filament.Fiber do
  @moduledoc false

  @enforce_keys [:id, :component]
  defstruct [
    # String.t()        — stable path-based identifier
    :id,
    # module()          — the component module (implements render/1)
    :component,
    # String.t() | nil  — nil for the root fiber
    :parent_id,
    # map()             — current props passed to this fiber
    props: %{},
    # %{non_neg_integer() => term()} — hook slot state map
    hook_slots: %{},
    # %{non_neg_integer() => {function(), kinds()}} — bubble-phase event
    # handlers and the event kinds each accepts
    event_handlers: %{},
    # [String.t()]      — direct child fiber IDs, in render order
    children: [],
    # %{non_neg_integer() => {function(), kinds()}} — capture-phase handlers
    capture_handlers: %{},
    # walked output of the last render, reused while the fiber's props are
    # unchanged and nothing below it is dirty; :unrendered before the first
    # render, since a render may itself return nil
    rendered: :unrendered,
    # nil | :self | :descendants — :self when the fiber's own state or a
    # value it reads changed; :descendants on its ancestors
    dirty: nil
  ]

  @type kinds :: :all | MapSet.t(atom())

  @type t :: %__MODULE__{
          id: String.t(),
          component: module(),
          props: map(),
          hook_slots: %{non_neg_integer() => term()},
          event_handlers: %{non_neg_integer() => {function(), kinds()}},
          capture_handlers: %{non_neg_integer() => {function(), kinds()}},
          rendered: term() | :unrendered,
          dirty: nil | :self | :descendants,
          children: [String.t()],
          parent_id: String.t() | nil
        }

  @doc """
  Creates a fiber. `:id` and `:component` are required; other fields default
  to an unrendered fiber with no state.

      iex> Filament.Fiber.new(id: "root", component: MyComponent)
      %Filament.Fiber{id: "root", component: MyComponent}
  """
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc """
  The stable, path-based id of a child fiber: its parent's id, module, and
  key or position among the parent's children of that module.

      iex> Filament.Fiber.child_id("root", MyApp.CartView, {:index, 0})
      "root.MyApp.CartView[0]"

      iex> Filament.Fiber.child_id("root", MyApp.CartView, {:key, 7})
      "root.MyApp.CartView[key=7]"
  """
  def child_id(parent_id, component, {:index, index}), do: "#{parent_id}.#{component}[#{index}]"
  def child_id(parent_id, component, {:key, key}), do: "#{parent_id}.#{component}[key=#{inspect(key)}]"
end
