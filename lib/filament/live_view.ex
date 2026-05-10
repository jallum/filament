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

  `static_subscribe: boolean` (default `true`) — when `true`, observable
  subscriptions are made during the static (HTTP) render pass, not just after
  the WebSocket connects. This produces fully-rendered initial HTML with real
  data, which is beneficial for SEO and perceived performance.

  When `false`, all `use_value` calls return their `:disconnected`
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

  import Phoenix.Component, only: [sigil_H: 2]

  alias Filament.Reconciler

  @callback root_component() :: module()

  @doc false
  def render(assigns) do
    ~H"""
    <%= @_filament_rendered %>
    <script data-phx-runtime-hook="FilamentKey">
      window.filament = window.filament || {
        handleEvent(hook, event, cb) {
          const ref = hook.el.dataset.ref;
          hook.handleEvent(ref ? ref + ":" + event : event, cb);
        }
      };
      window.phx_hook_FilamentKey = window.phx_hook_FilamentKey || function() {
        return {
          mounted() {
            this._handler = (e) => this.pushEvent(
              "filament:" + this.el.dataset.filamentWire,
              { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey }
            );
            window.addEventListener("keydown", this._handler);
          },
          destroyed() { window.removeEventListener("keydown", this._handler); }
        };
      };
    </script>
    """
  end

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
    static_subscribe = Keyword.get(opts, :static_subscribe, true)

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
          Reconciler.mount(component, props,
            owner_pid: self(),
            connected: subscribe_enabled
          )

        socket =
          socket
          |> Phoenix.Component.assign(:_filament_tree, tree)
          |> Phoenix.Component.assign(:_filament_rendered, Filament.Web.to_rendered(rendered))
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
        Filament.LiveView.render(assigns)
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
      Phoenix LiveView info handler for `Filament.Cell` updates.
      The subscriber tuple is `{owner_pid, fiber_id, slot_index}` (see
      `Filament.Hooks.cell_subscribe_fresh/3`); the value is whatever the cell
      transport sent — for the GenServer transport this is the raw observable
      state (identity-projected), so the user projection runs at render time.
      """
      def handle_info({:cell_update, subscriber, value}, socket) do
        tree = socket.assigns._filament_tree
        Filament.LiveView.handle_cell_update(tree, subscriber, value, socket, &rerender_from_root/2)
      end

      @doc """
      Phoenix LiveView info handler for `Filament.Cell` resubscribe signals.
      Sent by a cell transport when it can't deliver an update — typically because
      the subscriber's mailbox is saturated, or because the cell source restarted.
      Marks the slot `:needs_resubscribe`; the next render fetches a fresh value.
      """
      def handle_info({:cell_resubscribe, subscriber}, socket) do
        tree = socket.assigns._filament_tree
        Filament.LiveView.handle_cell_resubscribe(tree, subscriber, socket, &rerender_from_root/2)
      end

      # Re-render from the root fiber so _filament_rendered always contains the full
      # page output regardless of which child fiber triggered the update.
      defp rerender_from_root(socket, tree) do
        root_fiber = tree["root"]

        {new_tree, rendered, pending_effects} =
          Reconciler.update(tree, "root", root_fiber.props, owner_pid: self())

        socket
        |> Phoenix.Component.assign(:_filament_tree, new_tree)
        |> Phoenix.Component.assign(:_filament_rendered, Filament.Web.to_rendered(rendered))
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
        target_handler = Filament.FiberTree.get_event_handler(tree, fiber_id_str, handler_index)

        if is_function(target_handler, 2) do
          # 2-arity handlers (use_event_ref push pattern) need socket access for
          # `Phoenix.LiveView.push_event`, which is web-specific. They bypass
          # the Core dispatcher and run directly with the socket-aware shim.
          invoke_2arity_handler(target_handler, params, socket, "filament:" <> ref)
        else
          # All other handlers go through `Filament.Core.dispatch_event`, which
          # walks fiber ancestry firing capture handlers root-to-target before
          # the target's bubble handler. Backend-agnostic.
          _ = Filament.Core.dispatch_event(tree, fiber_id_str, handler_index, params)
          {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  defp invoke_2arity_handler(fun, params, socket, wire_ref) when is_function(fun, 2) do
    key = {__MODULE__, :push_socket, make_ref()}
    Process.put(key, socket)

    push = fn event, payload ->
      s = Process.get(key)
      Process.put(key, Phoenix.LiveView.push_event(s, "#{wire_ref}:#{event}", payload))
      :ok
    end

    fun.(params, push)
    {:noreply, Process.delete(key)}
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
  def handle_cell_update(tree, subscriber, value, socket, rerender_fn) do
    case subscriber do
      {_owner_pid, fiber_id, slot_index} ->
        apply_cell_update(tree, fiber_id, slot_index, value, socket, rerender_fn)

      _ ->
        {:noreply, socket}
    end
  end

  defp apply_cell_update(tree, fiber_id, slot_index, value, socket, rerender_fn) do
    case Map.get(tree, fiber_id) do
      nil ->
        {:noreply, socket}

      fiber ->
        new_slot = build_cell_slot(fiber.hook_slots, slot_index, value)
        new_slots = Map.put(fiber.hook_slots, slot_index, new_slot)
        new_tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
        {:noreply, rerender_fn.(socket, new_tree)}
    end
  end

  defp build_cell_slot(hook_slots, slot_index, value) do
    case Map.get(hook_slots, slot_index) do
      {:cell_subscribed, cell, _} -> {:cell_subscribed, cell, value}
      _ -> {:cell_subscribed, nil, value}
    end
  end

  @doc false
  def handle_cell_resubscribe(tree, subscriber, socket, rerender_fn) do
    case subscriber do
      {_owner_pid, fiber_id, slot_index} ->
        case Map.get(tree, fiber_id) do
          nil ->
            {:noreply, socket}

          fiber ->
            new_slots = Map.put(fiber.hook_slots, slot_index, :needs_resubscribe)
            new_tree = Map.put(tree, fiber_id, %{fiber | hook_slots: new_slots})
            {:noreply, rerender_fn.(socket, new_tree)}
        end

      _ ->
        {:noreply, socket}
    end
  end
end
