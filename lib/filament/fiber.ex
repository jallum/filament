defmodule Filament.Fiber do
  @moduledoc false

  @enforce_keys [:id, :component]
  defstruct [
    # String.t()        — stable path-based identifier
    :id,
    # term() | nil      — explicit :key from parent
    :key,
    # module()          — the component module (implements render/1)
    :component,
    # map()             — current props passed to this fiber
    :props,
    # %{non_neg_integer() => term()} — hook slot state map
    :hook_slots,
    # %{non_neg_integer() => function()} — event handlers registered this render
    :event_handlers,
    # [String.t()]      — ordered child fiber IDs
    :children,
    # String.t() | nil  — nil for the root fiber
    :parent_id,
    # :mounting | :stable | :updating | :unmounting
    :status
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          key: term() | nil,
          component: module(),
          props: map(),
          hook_slots: %{non_neg_integer() => term()},
          event_handlers: %{non_neg_integer() => function()},
          children: [String.t()],
          parent_id: String.t() | nil,
          status: :mounting | :stable | :updating | :unmounting
        }

  @doc """
  Creates a new fiber struct with defaults for optional fields.

  ## Options
    * `:id` (required) - String.t()
    * `:component` (required) - module()
    * `:key` - term() | nil (default: nil)
    * `:props` - map() (default: %{})
    * `:hook_slots` - list() (default: [])
    * `:children` - [String.t()] (default: [])
    * `:parent_id` - String.t() | nil (default: nil)
    * `:status` - atom() (default: :mounting)

  ## Examples

      iex> Filament.Fiber.new(id: "root", component: MyComponent)
      %Filament.Fiber{id: "root", component: MyComponent, status: :mounting}

      iex> Filament.Fiber.new(id: "root", component: MyComponent, props: %{value: "test"})
      %Filament.Fiber{id: "root", component: MyComponent, props: %{value: "test"}}
  """
  def new(opts) when is_list(opts) do
    props = Keyword.get(opts, :props, %{})
    hook_slots = Keyword.get(opts, :hook_slots, %{})
    event_handlers = Keyword.get(opts, :event_handlers, %{})
    children = Keyword.get(opts, :children, [])
    key = Keyword.get(opts, :key)
    parent_id = Keyword.get(opts, :parent_id)
    status = Keyword.get(opts, :status, :mounting)

    id = Keyword.fetch!(opts, :id)
    component = Keyword.fetch!(opts, :component)

    %__MODULE__{
      id: id,
      key: key,
      component: component,
      props: props,
      hook_slots: hook_slots,
      event_handlers: event_handlers,
      children: children,
      parent_id: parent_id,
      status: status
    }
  end

  @doc """
  Generates a stable, path-based child fiber ID.

  ## Rules
    * Indexed child (no key): parent_id <> "." <> to_string(component) <> "[" <> to_string(index) <> "]"
    * Keyed child: parent_id <> "." <> to_string(component) <> "[key=" <> inspect(key) <> "]"

  ## Examples

      iex> parent = %Filament.Fiber{id: "root", component: RootComponent, status: :stable}
      iex> Filament.Fiber.child_id(parent, MyApp.CartView, {:index, 0})
      "root.MyApp.CartView[0]"
  """
  def child_id(parent_fiber, component_module, {:index, index})
      when is_struct(parent_fiber, __MODULE__) and is_atom(component_module) and is_integer(index) and
             index >= 0 do
    "#{parent_fiber.id}.#{component_module}[#{index}]"
  end

  def child_id(parent_fiber, component_module, {:key, key})
      when is_struct(parent_fiber, __MODULE__) and is_atom(component_module) do
    "#{parent_fiber.id}.#{component_module}[key=#{inspect(key)}]"
  end
end
