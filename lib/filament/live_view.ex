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

  `static_subscribe: boolean` (default `true`) — when `true`, the static (HTTP)
  render reads each source's current value, so the initial HTML has real data,
  which is beneficial for SEO and perceived performance. The static render
  doesn't subscribe: it calls `handle_current/1`, not `handle_subscribe/2`, and
  leaves no subscription behind on the HTTP connection's process. The
  connected process subscribes on mount.

  When `false`, all `use_value` calls return their `:disconnected`
  value during the static render; real data appears after the WebSocket connects.

      defmodule MyApp.MyLiveView do
        use Filament.LiveView, static_subscribe: true

        def root_component(), do: MyApp.MyComponent
      end
  """

  import Phoenix.Component, only: [sigil_H: 2]

  alias Filament.Reconciler

  require Logger

  @host_messages [:filament_set_state, :cell_update, :cell_updates, :cell_resubscribe]

  @callback root_component() :: module()

  @doc false
  def render(assigns) do
    ~H"<%= @_filament_rendered %>"
  end

  @runtime_assets_js File.read!(Path.join(:code.priv_dir(:filament), "static/filament.js"))
  @external_resource Path.join(:code.priv_dir(:filament), "static/filament.js")

  @doc """
  Renders the Filament runtime JS — the `window.filament.handleEvent`
  helper and the `FilamentKey` window-keydown hook.

  Drop this once into your root layout, before the `LiveSocket`
  initialization:

      <Filament.LiveView.runtime_assets />
      <script>
        let liveSocket = new LiveSocket("/live", Socket, {...})
        liveSocket.connect()
      </script>

  The injected script is idempotent — safe to render multiple times if
  the layout changes between mounts.

  ## What it provides

    * `window.filament.handleEvent(hook, event, cb)` — used by JS hooks
      that pair with `Filament.Experimental.Hooks.use_event_ref/1` 2-arity
      handlers; scopes events to the wire ref so multiple instances of
      the same hook on a page never cross-talk.

    * The `FilamentKey` LiveView hook — registered via
      `data-phx-runtime-hook` so consumers don't need to thread it into
      their `LiveSocket` `hooks:` object. Drives the `on_key` template
      attribute by listening to `window` keydown events and pushing
      them at the right fiber.

  ## Background

  Earlier versions inlined this JS in every `Filament.LiveView` render,
  which shipped the same script on every WebSocket diff. Moving it to a
  one-time layout component keeps it out of the per-render diff stream.
  """
  def runtime_assets(assigns) do
    assigns = Phoenix.Component.assign(assigns, :__filament_js__, @runtime_assets_js)

    ~H"""
    <script data-phx-runtime-hook="FilamentKey"><%= Phoenix.HTML.raw(@__filament_js__) %></script>
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

    static_sources = if static_subscribe, do: :current, else: :disconnected

    quote do
      @behaviour Filament.LiveView

      use Phoenix.LiveView

      @doc """
      Phoenix LiveView mount callback.
      """
      def mount(_params, _session, socket) do
        component = root_component()
        props = build_props(socket)

        {tree, rendered, pending_effects} =
          Reconciler.mount(component, props,
            owner_pid: self(),
            target: Filament.Web,
            sources: if(Phoenix.LiveView.connected?(socket), do: :subscribe, else: unquote(static_sources))
          )

        socket =
          socket
          |> Filament.LiveView.assign_render(tree, rendered, pending_effects)
          |> Phoenix.LiveView.attach_hook(:filament_effects, :after_render, &Filament.LiveView.run_pending_effects/1)

        {:ok, socket}
      end

      # Converts socket assigns to props map for the root component.
      defp build_props(socket) do
        Filament.LiveView.extract_props(socket.assigns, root_component())
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
      registered by `Filament.Hooks.register_event_handler/3`). All other events are forwarded to the root
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
        Filament.LiveView.dispatch_component_event(event, params, socket)
      end

      @doc """
      Phoenix LiveView info handler.

      Applies Filament's own messages — `use_state` setters and cell transport
      updates — and re-renders from the root when they change the tree. Other
      messages are logged and ignored, as Phoenix does for a view without
      `handle_info/2`. A view that handles its own messages ends with
      `def handle_info(msg, socket), do: super(msg, socket)`.
      """
      def handle_info(message, socket) when elem(message, 0) in unquote(@host_messages) do
        {:noreply, Filament.LiveView.apply_to_socket(socket, message)}
      end

      def handle_info(message, socket) do
        Filament.LiveView.unhandled_info(__MODULE__, message)
        {:noreply, socket}
      end

      # Ensure render/1 is defined
      @doc """
      Phoenix LiveView terminate callback. Unmounts the Filament tree, running
      effect cleanups and ending subscriptions. Phoenix calls it when the
      client disconnects or the view shuts down, but after a crash only if the
      view traps exits; cell transports drop a dead owner's subscriptions
      either way.
      """
      def terminate(_reason, socket) do
        if tree = socket.assigns[:_filament_tree], do: Reconciler.unmount(tree)
        :ok
      end

      defoverridable mount: 3, render: 1, handle_event: 3, handle_info: 2, terminate: 2
    end
  end

  @doc """
  Build the prop map for `component` from a LiveView socket's assigns.

  Selects only assigns whose keys appear in `component.__props__()`. This
  is an allowlist — assigns Phoenix LiveView injects (`:flash`,
  `:live_action`, `:__changed__`, etc.) are not props and never reach
  the component, regardless of what new internal assigns Phoenix adds
  in future releases.

  Components without a `__props__/0` (i.e. not defined via `defcomponent`)
  receive an empty prop map.
  """
  @spec extract_props(map(), module()) :: map()
  def extract_props(assigns, component) when is_atom(component) do
    # Phoenix doesn't pre-load route modules on mount, so the component
    # module may not be loaded yet — function_exported?/3 would return
    # false and we'd silently drop every prop. ensure_loaded?/1 forces
    # the load before we ask.
    if Code.ensure_loaded?(component) and function_exported?(component, :__props__, 0) do
      props = Enum.map(component.__props__(), fn {name, _meta} -> name end)
      slots = if function_exported?(component, :__slots__, 0), do: Enum.map(component.__slots__(), & &1.name), else: []
      allowed = props ++ slots
      Map.take(assigns, allowed)
    else
      %{}
    end
  end

  @doc false
  def dispatch_filament_event(ref, params, socket) do
    case Filament.Hooks.parse_event_ref(ref) do
      {:ok, fiber_id_str, handler_index} ->
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

      :error ->
        {:noreply, socket}
    end
  end

  defp invoke_2arity_handler(fun, params, socket, wire_ref) when is_function(fun, 2) do
    # The 2-arity handler form needs a `push/2` fn that closes over the LV
    # socket. We thread the socket through the process dictionary so each
    # push.(event, payload) accumulates into the same socket; the final
    # value is what we return. try/after ensures the pdict slot is cleared
    # even if the handler raises — otherwise the entry would leak until
    # the LV process dies.
    key = {__MODULE__, :push_socket, make_ref()}
    Process.put(key, socket)

    push = fn event, payload ->
      s = Process.get(key)
      Process.put(key, Phoenix.LiveView.push_event(s, "#{wire_ref}:#{event}", payload))
      :ok
    end

    try do
      fun.(params, push)
      {:noreply, Process.get(key)}
    after
      Process.delete(key)
    end
  end

  @doc false
  def dispatch_component_event(event, params, socket) do
    tree = socket.assigns._filament_tree
    root_fiber = tree["root"]

    if function_exported?(root_fiber.component, :handle_event, 3) do
      {:noreply, render_root(socket, tree, root_fiber.component.handle_event(event, params, root_fiber.props))}
    else
      {:noreply, socket}
    end
  end

  # ── Host messages (shared by LiveView, LiveComponent and Filament.Test) ──

  @doc """
  Apply a Filament host message to the fiber tree without rendering.

  A host process receives `{:filament_set_state, fiber_id, slot_index, token,
  value}` from `use_state` setters, and `{:cell_update, subscriber, value}`,
  `{:cell_updates, [{subscriber, value}]}` and `{:cell_resubscribe, subscriber}`
  from cell transports, and `{:cell_resubscribe, ref, :process, pid, reason}`
  when a source's monitored process exits or `use_value` retries a source it
  couldn't reach.

  Returns `{:rerender, tree}` when the message marked a fiber dirty, so the
  host should re-render from the root. Returns `{:ok, tree}` when no render is
  needed: the message is stale (its fiber is gone or remounted, or its
  subscription was replaced), the value is unchanged, only a cell's cached raw
  value changed, or the message isn't Filament's.
  """
  @spec apply_message(map(), term()) :: {:rerender | :ok, map()}
  def apply_message(tree, {:filament_set_state, fiber_id, slot_index, token, new_value}) do
    with %{hook_slots: slots} = fiber <- Map.get(tree, fiber_id),
         {:state, old_value, setter, ^token} when old_value !== new_value <- Map.get(slots, slot_index) do
      tree = put_slot(tree, fiber, slot_index, {:state, new_value, setter, token})
      {:rerender, Reconciler.mark_dirty(tree, fiber_id)}
    else
      _ -> {:ok, tree}
    end
  end

  def apply_message(tree, {:cell_update, subscriber, value}) do
    update_cell_slot(tree, subscriber, &Filament.HookSlot.put_cell_value(&1, value))
  end

  def apply_message(tree, {:cell_updates, updates}) when is_list(updates) do
    for {subscriber, value} <- updates, reduce: {:ok, tree} do
      {status, tree} ->
        case apply_message(tree, {:cell_update, subscriber, value}) do
          {:rerender, tree} -> {:rerender, tree}
          {:ok, tree} -> {status, tree}
        end
    end
  end

  def apply_message(tree, {:cell_resubscribe, subscriber}) do
    update_cell_slot(tree, subscriber, &{Filament.HookSlot.resubscribe(&1, subscriber), true})
  end

  # A source's process exited, or a retry is due: the slot holding `ref`
  # subscribes again on the next render.
  def apply_message(tree, {:cell_resubscribe, ref, :process, _process, _reason}) do
    case Enum.find_value(tree, &source_down(&1, ref)) do
      {fiber_id, fiber, slot_index, new_slot} ->
        {:rerender, tree |> put_slot(fiber, slot_index, new_slot) |> Reconciler.mark_dirty(fiber_id)}

      nil ->
        {:ok, tree}
    end
  end

  def apply_message(tree, _message), do: {:ok, tree}

  defp source_down({fiber_id, fiber}, ref) do
    Enum.find_value(fiber.hook_slots, fn {slot_index, slot} ->
      case Filament.HookSlot.source_down(slot, ref) do
        {:ok, new_slot} -> {fiber_id, fiber, slot_index, new_slot}
        _ -> nil
      end
    end)
  end

  defp update_cell_slot(tree, {_owner, fiber_id, slot_index, _generation} = subscriber, update) do
    with %{hook_slots: %{^slot_index => slot}} = fiber <- Map.get(tree, fiber_id),
         true <- Filament.HookSlot.matches_subscriber?(slot, subscriber) do
      {new_slot, changed?} = update.(slot)
      tree = put_slot(tree, fiber, slot_index, new_slot)
      if changed?, do: {:rerender, Reconciler.mark_dirty(tree, fiber_id)}, else: {:ok, tree}
    else
      _ -> {:ok, tree}
    end
  end

  defp update_cell_slot(tree, _subscriber, _update), do: {:ok, tree}

  defp put_slot(tree, fiber, slot_index, slot) do
    Map.put(tree, fiber.id, %{fiber | hook_slots: Map.put(fiber.hook_slots, slot_index, slot)})
  end

  # ── Socket helpers (shared by LiveView and LiveComponent) ────────────────

  @doc false
  def apply_to_socket(socket, message) do
    case apply_message(socket.assigns._filament_tree, message) do
      {:rerender, tree} -> render_root(socket, tree, tree["root"].props)
      {:ok, tree} -> Phoenix.Component.assign(socket, :_filament_tree, tree)
    end
  end

  # The output always covers the whole tree, whichever fiber changed.
  defp render_root(socket, tree, props) do
    {tree, rendered, pending_effects} =
      Reconciler.update(tree, "root", props, owner_pid: self(), target: Filament.Web)

    assign_render(socket, tree, rendered, pending_effects)
  end

  @doc false
  def assign_render(socket, tree, rendered, pending_effects) do
    socket
    |> Phoenix.Component.assign(:_filament_tree, tree)
    |> Phoenix.Component.assign(:_filament_rendered, rendered)
    |> Phoenix.Component.assign(:_filament_pending_effects, pending_effects)
  end

  @doc false
  def unhandled_info(module, message) do
    Logger.warning("undefined handle_info in #{inspect(module)}. Unhandled message: #{inspect(message)}")
  end
end
