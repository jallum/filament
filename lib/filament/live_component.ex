defmodule Filament.LiveComponent do
  @moduledoc """
  Phoenix LiveComponent adapter for embedding a Filament component inside a regular
  Phoenix LiveView.

  ## Usage

      <.live_component
        module={Filament.LiveComponent}
        id="unique-id"
        component={MyApp.MyComponent}
        my_prop="value"
        other_prop={@something}
      />

  All assigns other than `id` and `component` are passed as props to the Filament
  component.

  ## Observable updates

  Because `Filament.LiveComponent` runs inside the parent LiveView process,
  observable update messages (`:filament_set_state`, `:filament_observable_update`,
  `:filament_observable_resubscribe`) arrive at the **parent** LiveView's
  `handle_info/2`. The parent must forward them to the component:

      def handle_info({type, _fid, _slot, _val} = msg, socket)
          when type in [:filament_set_state, :filament_observable_update,
                        :filament_observable_resubscribe] do
        Phoenix.LiveView.send_update(Filament.LiveComponent,
          id: "my-id", filament_msg: msg)
        {:noreply, socket}
      end

  This is a Phase 1 limitation. Phase 2 will add automatic forwarding via a
  host LiveView helper.
  """

  use Phoenix.LiveComponent

  alias Filament.Reconciler

  @impl true
  def mount(socket) do
    socket =
      Phoenix.LiveView.attach_hook(
        socket,
        :filament_effects,
        :after_render,
        &Filament.LiveView.run_pending_effects/1
      )

    {:ok,
     socket
     |> Phoenix.Component.assign(:_filament_tree, nil)
     |> Phoenix.Component.assign(:_filament_pending_effects, [])}
  end

  @impl true
  def update(%{filament_msg: msg} = _assigns, socket) do
    tree = socket.assigns._filament_tree
    owner_pid = self()

    case process_filament_msg(msg, tree, owner_pid) do
      {:ok, new_tree, new_rendered, pending_effects} ->
        {:ok,
         socket
         |> Phoenix.Component.assign(:_filament_tree, new_tree)
         |> Phoenix.Component.assign(:_filament_rendered, new_rendered)
         |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}

      :ignore ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    component = Map.fetch!(assigns, :component)
    excluded = [:id, :component, :filament_msg]
    props = assigns |> Map.drop(excluded) |> Map.new()

    case socket.assigns._filament_tree do
      nil ->
        {tree, rendered, pending_effects} =
          Reconciler.mount(component, props, owner_pid: self())

        {:ok,
         socket
         |> Phoenix.Component.assign(:_filament_tree, tree)
         |> Phoenix.Component.assign(:_filament_rendered, rendered)
         |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)
         |> Phoenix.Component.assign(:_filament_component, component)}

      tree ->
        {new_tree, rendered, pending_effects} =
          Reconciler.update(tree, "root", props, owner_pid: self())

        {:ok,
         socket
         |> Phoenix.Component.assign(:_filament_tree, new_tree)
         |> Phoenix.Component.assign(:_filament_rendered, rendered)
         |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}
    end
  end

  @impl true
  def handle_event("filament:" <> ref, params, socket) do
    case String.split(ref, ":", parts: 2) do
      [fiber_id_str, index_str] ->
        handler_index = String.to_integer(index_str)
        tree = socket.assigns._filament_tree
        handler = Filament.FiberTree.get_event_handler(tree, fiber_id_str, handler_index)

        case handler do
          nil ->
            {:noreply, socket}

          fun when is_function(fun, 0) ->
            fun.()
            {:noreply, socket}

          fun when is_function(fun, 1) ->
            fun.(params)
            {:noreply, socket}

          _other ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns._filament_rendered
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp process_filament_msg(
         {:filament_set_state, fiber_id, slot_index, new_value},
         tree,
         owner_pid
       ) do
    case Map.get(tree, fiber_id) do
      nil ->
        :ignore

      fiber ->
        existing = Map.get(fiber.hook_slots, slot_index, {nil, nil})
        setter = elem(existing, 1)
        new_slots = Map.put(fiber.hook_slots, slot_index, {new_value, setter})
        new_tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

        {new_tree, rendered, pending_effects} =
          Reconciler.update(new_tree, fiber_id, fiber.props, owner_pid: owner_pid)

        {:ok, new_tree, rendered, pending_effects}
    end
  end

  defp process_filament_msg(
         {:filament_observable_update, fiber_id, slot_index, new_value},
         tree,
         owner_pid
       ) do
    case Map.get(tree, fiber_id) do
      nil ->
        :ignore

      fiber ->
        existing = Map.get(fiber.hook_slots, slot_index, :uninitialized)

        server =
          case existing do
            {:subscribed, s, _v} -> s
            _ -> nil
          end

        new_slots = Map.put(fiber.hook_slots, slot_index, {:subscribed, server, new_value})
        new_tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

        {new_tree, rendered, pending_effects} =
          Reconciler.update(new_tree, fiber_id, fiber.props, owner_pid: owner_pid)

        {:ok, new_tree, rendered, pending_effects}
    end
  end

  defp process_filament_msg(
         {:filament_observable_resubscribe, fiber_id, slot_index},
         tree,
         owner_pid
       ) do
    case Map.get(tree, fiber_id) do
      nil ->
        :ignore

      fiber ->
        new_slots = Map.put(fiber.hook_slots, slot_index, :needs_resubscribe)
        new_tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

        {new_tree, rendered, pending_effects} =
          Reconciler.update(new_tree, fiber_id, fiber.props, owner_pid: owner_pid)

        {:ok, new_tree, rendered, pending_effects}
    end
  end

  defp process_filament_msg(_unknown, _tree, _owner_pid), do: :ignore
end
