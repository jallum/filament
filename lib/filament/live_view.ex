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

  @doc """
  Runs pending effects accumulated during the render pass.
  Attached via attach_hook as an :after_render callback.
  """
  def run_pending_effects(socket) do
    effects = Map.get(socket.assigns, :_filament_pending_effects, [])

    if effects == [] do
      socket
    else
      # Run each effect and collect cleanup functions
      {cleanups, socket} =
        Enum.reduce(effects, {[], socket}, fn
          {slot_index, fiber_id, effect_fn, deps}, {acc_cleanups, acc_socket} ->
            cleanup = effect_fn.()
            {[{slot_index, fiber_id, cleanup, deps} | acc_cleanups], acc_socket}
        end)

      # Store cleanup fns back into hook_slots of their respective fibers
      tree = socket.assigns._filament_tree

      new_tree =
        Enum.reduce(cleanups, tree, fn
          {_index, _fiber_id, nil, _deps}, t ->
            t

          {index, fiber_id, cleanup_fn, deps}, t ->
            fiber = t[fiber_id]
            new_slots = Map.put(fiber.hook_slots, index, {deps, cleanup_fn})
            Map.put(t, fiber_id, %{fiber | hook_slots: new_slots})
        end)

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
        {tree, rendered, pending_effects} = Reconciler.mount(component, props, owner_pid: self())

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
      Forwards events to root component if it defines handle_event/3.
      """
      def handle_event(event, params, socket) do
        case String.split(event, ":") do
          ["filament" | _rest] ->
            # Filament internal events - currently noop
            {:noreply, socket}

          _ ->
            # Regular Phoenix events - forward to root component if defined
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
      end

      @doc """
      Phoenix LiveView info handler.
      """
      def handle_info({:filament_update, _fiber_id, _new_state}, socket) do
        # Track D will implement observable updates
        {:noreply, socket}
      end

      # Ensure render/1 is defined
      defoverridable mount: 3, render: 1, handle_event: 3, handle_info: 2
    end
  end
end
