defmodule Filament.LiveView do
  @moduledoc """
  Phoenix LiveView adapter for Filament components.

  This module provides the integration point between Filament's fiber-based
  reconciliation and Phoenix LiveView's rendering engine.

  ## Usage

  In your LiveView module:

      defmodule MyApp.MyLiveView do
        use Filament.LiveView

        def root_component(), do: MyApp.MyComponent
      end
  """

  alias Filament.Reconciler

  @callback root_component() :: module()

  @doc false
  def apply_effects(pending_effects, fiber_tree) do
    Enum.reduce(pending_effects, {fiber_tree, 0}, fn
      {_slot_index, fiber_id, _effect_fn, _deps, _old_cleanup}, {acc_tree, count}
      when not is_map_key(acc_tree, fiber_id) ->
        {acc_tree, count}

      {slot_index, fiber_id, effect_fn, deps, old_cleanup}, {acc_tree, count} ->
        # Run old cleanup if present
        if is_function(old_cleanup, 0), do: old_cleanup.()

        # Run the new effect
        new_cleanup = effect_fn.()
        new_cleanup = if is_function(new_cleanup, 0), do: new_cleanup, else: nil

        # Store {deps, new_cleanup} back into the fiber's hook_slots
        fiber = acc_tree[fiber_id]

        new_slots = Map.put(fiber.hook_slots, slot_index, {deps, new_cleanup})
        new_tree = Map.put(acc_tree, fiber_id, %{fiber | hook_slots: new_slots})

        {new_tree, count + 1}
    end)
  end

  @doc """
  Runs pending effects accumulated during the render pass.
  Attached via attach_hook as an :after_render callback.
  """
  def run_pending_effects(socket) do
    effects = Map.get(socket.assigns, :_filament_pending_effects, [])

    if effects == [] do
      socket
    else
      tree = socket.assigns._filament_tree
      {new_tree, _ran} = apply_effects(effects, tree)

      socket
      |> Phoenix.Component.assign(:_filament_tree, new_tree)
      |> Phoenix.Component.assign(:_filament_pending_effects, [])
    end
  end

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView
      @behaviour Filament.LiveView

      @doc """
      Phoenix LiveView mount callback.
      """
      def mount(_params, _session, socket) do
        component = root_component()
        props = build_props(socket)
        connected = Phoenix.LiveView.connected?(socket)

        {tree, rendered, pending_effects} =
          Reconciler.mount(component, props, owner_pid: self(), connected: connected)

        socket =
          socket
          |> Phoenix.Component.assign(:_filament_tree, tree)
          |> Phoenix.Component.assign(:_filament_rendered, rendered)
          |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)

        socket =
          Phoenix.LiveView.attach_hook(
            socket,
            :filament_effects,
            :after_render,
            &Filament.LiveView.run_pending_effects/1
          )

        {:ok, socket}
      end

      # Converts socket assigns to props map for the root component.
      defp build_props(socket) do
        excludes = [
          :_filament_tree,
          :_filament_rendered,
          :_filament_pending_effects,
          :flash,
          :live_action,
          :socket,
          :__changed__
        ]

        socket.assigns
        |> Map.reject(fn {k, _v} -> k in excludes end)
        |> Map.new()
      end

      @doc """
      Phoenix LiveView render callback.
      Returns the pre-rendered Filament output.
      """
      def render(assigns) do
        assigns._filament_rendered
      end

      @doc """
      Phoenix LiveView event handler.
      Routes filament: events to registered fiber handlers; forwards all other
      events to the root component if it defines handle_event/3.
      """
      def handle_event("filament:" <> ref, params, socket) do
        case String.split(ref, ":", parts: 2) do
          [fiber_id_str, index_str] ->
            handler_index = String.to_integer(index_str)
            tree = socket.assigns._filament_tree
            handler = Filament.FiberTree.get_event_handler(tree, fiber_id_str, handler_index)

            case handler do
              nil ->
                # Stale ref (fiber unmounted between render and click)
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

          _other ->
            {:noreply, socket}
        end
      end

      def handle_event(event, params, socket) do
        tree = socket.assigns._filament_tree
        root_fiber = tree["root"]

        case function_exported?(root_fiber.component, :handle_event, 3) do
          true ->
            {new_props, _} =
              root_fiber.component.handle_event(event, params, root_fiber.props)

            {new_tree, rendered, pending_effects} =
              Reconciler.update(tree, "root", new_props, owner_pid: self())

            {:noreply,
             socket
             |> Phoenix.Component.assign(:_filament_tree, new_tree)
             |> Phoenix.Component.assign(:_filament_rendered, rendered)
             |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}

          false ->
            {:noreply, socket}
        end
      end

      @doc """
      Phoenix LiveView info handler for Filament state changes.
      """
      def handle_info({:filament_set_state, fiber_id, slot_index, new_value}, socket) do
        tree = socket.assigns._filament_tree

        case Map.get(tree, fiber_id) do
          nil ->
            # Fiber may have been unmounted — ignore stale state update
            {:noreply, socket}

          fiber ->
            # Preserve existing setter when updating value (stable setter pattern)
            existing = Map.get(fiber.hook_slots, slot_index, {nil, nil})
            setter = elem(existing, 1)
            new_slots = Map.put(fiber.hook_slots, slot_index, {new_value, setter})
            tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

            # Re-render the fiber with its current props
            {new_tree, rendered, pending_effects} =
              Reconciler.update(tree, fiber_id, fiber.props, owner_pid: self())

            {:noreply,
             socket
             |> Phoenix.Component.assign(:_filament_tree, new_tree)
             |> Phoenix.Component.assign(:_filament_rendered, rendered)
             |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}
        end
      end

      @doc """
      Phoenix LiveView info handler for observable updates.
      """
      def handle_info({:filament_observable_update, fiber_id, slot_index, new_value}, socket) do
        tree = socket.assigns._filament_tree

        case Map.get(tree, fiber_id) do
          nil ->
            {:noreply, socket}

          fiber ->
            # Preserve the observable server (stored in the slot) while updating the value
            existing = Map.get(fiber.hook_slots, slot_index, :uninitialized)

            server =
              case existing do
                {:subscribed, s, _v} -> s
                _ -> nil
              end

            new_slots = Map.put(fiber.hook_slots, slot_index, {:subscribed, server, new_value})
            tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

            # Re-render the fiber with its current props
            {new_tree, rendered, pending_effects} =
              Reconciler.update(tree, fiber_id, fiber.props, owner_pid: self())

            {:noreply,
             socket
             |> Phoenix.Component.assign(:_filament_tree, new_tree)
             |> Phoenix.Component.assign(:_filament_rendered, rendered)
             |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}
        end
      end

      @doc """
      Phoenix LiveView info handler for observable resubscribe signals.
      Triggered when a subscriber's mailbox is saturated; forces re-subscription on next render.
      """
      def handle_info({:filament_observable_resubscribe, fiber_id, slot_index}, socket) do
        tree = socket.assigns._filament_tree

        case Map.get(tree, fiber_id) do
          nil ->
            {:noreply, socket}

          fiber ->
            new_slots = Map.put(fiber.hook_slots, slot_index, :needs_resubscribe)
            tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})

            {new_tree, rendered, pending_effects} =
              Reconciler.update(tree, fiber_id, fiber.props, owner_pid: self())

            {:noreply,
             socket
             |> Phoenix.Component.assign(:_filament_tree, new_tree)
             |> Phoenix.Component.assign(:_filament_rendered, rendered)
             |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}
        end
      end

      # Ensure render/1 is defined
      defoverridable mount: 3, render: 1, handle_event: 3, handle_info: 2
    end
  end
end
