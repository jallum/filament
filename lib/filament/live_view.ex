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

  ## Options

  `static_subscribe: boolean` (default `false`) — when `true`, observable
  subscriptions are made during the static (HTTP) render pass, not just after
  the WebSocket connects. This produces fully-rendered initial HTML with real
  data, which is beneficial for SEO and perceived performance.

  When `false` (default), all `use_observable` calls return their `:disconnected`
  value during the static render; real data appears after the WebSocket connects.

  Note: Phoenix LiveView uses separate OS processes for the static render and
  the connected session. With `static_subscribe: true` the static process
  subscribes, renders, then terminates — subscriptions are cleaned up
  automatically. The connected process re-subscribes normally on mount.

      defmodule MyApp.MyLiveView do
        use Filament.LiveView, static_subscribe: true

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
        new_cleanup = if is_function(new_cleanup, 0), do: new_cleanup

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

  defmacro __using__(opts) do
    static_subscribe = Keyword.get(opts, :static_subscribe, false)

    quote do
      @behaviour Filament.LiveView

      use Phoenix.LiveView

      @doc """
      Phoenix LiveView mount callback.
      """
      def mount(_params, _session, socket) do
        component = root_component()
        props = build_props(socket)
        subscribe_enabled = unquote(static_subscribe) or Phoenix.LiveView.connected?(socket)

        {tree, rendered, pending_effects} =
          Reconciler.mount(component, props, owner_pid: self(), connected: subscribe_enabled)

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
        Filament.LiveView.extract_props(socket.assigns)
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

      Routes `filament:` wire events to registered fiber handlers (event closures
      registered by `event_at/2`). All other events are forwarded to the root
      component if it defines `handle_event/3`.

      The component-level `handle_event/3` callback receives
      `(event, params, props)` and must return the (possibly updated) props map.
      Filament then re-renders the root fiber with the returned props.

          def handle_event("increment", _params, props) do
            Map.update!(props, :count, &(&1 + 1))
          end
      """
      def handle_event("filament:" <> ref, params, socket) do
        Filament.LiveView.dispatch_filament_event(ref, params, socket)
      end

      def handle_event(event, params, socket) do
        Filament.LiveView.dispatch_component_event(event, params, socket, &rerender_from_root/2)
      end

      @doc """
      Phoenix LiveView info handler for Filament state changes.
      """
      def handle_info({:filament_set_state, fiber_id, slot_index, new_value}, socket) do
        tree = socket.assigns._filament_tree
        Filament.LiveView.handle_set_state(tree, fiber_id, slot_index, new_value, socket, &rerender_from_root/2)
      end

      @doc """
      Phoenix LiveView info handler for observable updates.
      Receives a batched list of `{fiber_id, slot_index, value}` tuples from a single
      `notify_observers/1` call and applies them all before re-rendering.
      """
      def handle_info({:filament_observable_updates, updates}, socket) do
        tree = socket.assigns._filament_tree
        Filament.LiveView.handle_observable_updates(tree, updates, socket, &rerender_from_root/2)
      end

      @doc """
      Phoenix LiveView info handler for observable resubscribe signals.
      Triggered when a subscriber's mailbox is saturated; forces re-subscription on next render.
      """
      def handle_info({:filament_observable_resubscribe, fiber_id, slot_index}, socket) do
        tree = socket.assigns._filament_tree
        Filament.LiveView.handle_observable_resubscribe(tree, fiber_id, slot_index, socket, &rerender_from_root/2)
      end

      # Re-render from the root fiber so _filament_rendered always contains the full
      # page output regardless of which child fiber triggered the update.
      defp rerender_from_root(socket, tree) do
        root_fiber = tree["root"]

        {new_tree, rendered, pending_effects} =
          Reconciler.update(tree, "root", root_fiber.props, owner_pid: self())

        socket
        |> Phoenix.Component.assign(:_filament_tree, new_tree)
        |> Phoenix.Component.assign(:_filament_rendered, rendered)
        |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)
      end

      # Ensure render/1 is defined
      defoverridable mount: 3, render: 1, handle_event: 3, handle_info: 2
    end
  end

  @doc false
  def extract_props(assigns) do
    excludes = [
      :_filament_tree,
      :_filament_rendered,
      :_filament_pending_effects,
      :flash,
      :live_action,
      :socket,
      :__changed__
    ]

    assigns
    |> Map.reject(fn {k, _v} -> k in excludes end)
    |> Map.new()
  end

  @doc false
  def dispatch_filament_event(ref, params, socket) do
    case String.split(ref, ":", parts: 2) do
      [fiber_id_str, index_str] ->
        handler_index = String.to_integer(index_str)
        tree = socket.assigns._filament_tree
        handler = Filament.FiberTree.get_event_handler(tree, fiber_id_str, handler_index)
        invoke_event_handler(handler, params, socket)

      _other ->
        {:noreply, socket}
    end
  end

  defp invoke_event_handler(nil, _params, socket), do: {:noreply, socket}

  defp invoke_event_handler(fun, _params, socket) when is_function(fun, 0) do
    fun.()
    {:noreply, socket}
  end

  defp invoke_event_handler(fun, params, socket) when is_function(fun, 1) do
    fun.(params)
    {:noreply, socket}
  end

  @doc false
  def dispatch_component_event(event, params, socket, _rerender_fn) do
    tree = socket.assigns._filament_tree
    root_fiber = tree["root"]

    if function_exported?(root_fiber.component, :handle_event, 3) do
      new_props = root_fiber.component.handle_event(event, params, root_fiber.props)

      {new_tree, rendered, pending_effects} =
        Reconciler.update(tree, "root", new_props, owner_pid: self())

      {:noreply,
       socket
       |> Phoenix.Component.assign(:_filament_tree, new_tree)
       |> Phoenix.Component.assign(:_filament_rendered, rendered)
       |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)}
    else
      {:noreply, socket}
    end
  end

  @doc false
  def handle_set_state(tree, fiber_id, slot_index, new_value, socket, rerender_fn) do
    case Map.get(tree, fiber_id) do
      nil ->
        {:noreply, socket}

      fiber ->
        existing = Map.get(fiber.hook_slots, slot_index, {nil, nil})
        setter = elem(existing, 1)
        new_slots = Map.put(fiber.hook_slots, slot_index, {new_value, setter})
        tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
        {:noreply, rerender_fn.(socket, tree)}
    end
  end

  @doc false
  def handle_observable_updates(tree, updates, socket, rerender_fn) do
    new_tree = apply_observable_updates(tree, updates)

    if Enum.any?(updates, fn {fid, _, _} -> Map.has_key?(tree, fid) end) do
      {:noreply, rerender_fn.(socket, new_tree)}
    else
      {:noreply, socket}
    end
  end

  @doc false
  def apply_observable_updates(tree, updates) do
    Enum.reduce(updates, tree, fn {fiber_id, slot_index, new_value}, acc ->
      case Map.get(acc, fiber_id) do
        nil -> acc
        fiber -> apply_slot_update(acc, fiber_id, fiber, slot_index, new_value)
      end
    end)
  end

  defp apply_slot_update(tree, fiber_id, fiber, slot_index, new_value) do
    new_slot =
      case Map.get(fiber.hook_slots, slot_index, :uninitialized) do
        {:subscribed, s, _} -> {:subscribed, s, new_value}
        _ -> {:subscribed, nil, new_value}
      end

    new_slots = Map.put(fiber.hook_slots, slot_index, new_slot)
    Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
  end

  @doc false
  def handle_observable_resubscribe(tree, fiber_id, slot_index, socket, rerender_fn) do
    case Map.get(tree, fiber_id) do
      nil ->
        {:noreply, socket}

      fiber ->
        new_slots = Map.put(fiber.hook_slots, slot_index, :needs_resubscribe)
        tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
        {:noreply, rerender_fn.(socket, tree)}
    end
  end
end
