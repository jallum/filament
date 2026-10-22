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
  observable update messages (`:filament_set_state`, `:cell_update`, `:cell_updates`,
  `:cell_resubscribe`) arrive at the **parent**
  LiveView's `handle_info/2`. The parent must forward them to the component:

      def handle_info(msg, socket)
          when elem(msg, 0) in [:filament_set_state, :cell_update, :cell_updates, :cell_resubscribe] do
        Phoenix.LiveView.send_update(Filament.LiveComponent, id: "my-id", filament_msg: msg)
        {:noreply, socket}
      end

  Forwarding to every Filament LiveComponent on the page is safe: a message
  that isn't a component's own is ignored by it.

  ## Navigation

  A navigation a component asks for with `Filament.Hooks.use_navigate/0`
  arrives at the parent too, as `{:filament_navigate, opts}`. The parent
  applies it to its own socket:

      def handle_info({:filament_navigate, opts}, socket),
        do: {:noreply, Filament.LiveView.navigate(socket, opts)}

  ## Removing the component

  LiveView tells a LiveComponent nothing when the parent stops rendering it,
  so its tree is never unmounted: its `use_value` subscriptions last until
  the parent LiveView exits, and its effect cleanups never run. Keep the
  component rendered and switch what it shows through its props, or render
  a component that comes and goes inside a `Filament.LiveView`, which
  unmounts its tree when it terminates.

  ## `on_key`

  `on_key` needs the `FilamentKey` hook's script, which `Filament.LiveView`
  includes in its output but a LiveView of your own doesn't. Render
  `Filament.LiveView.runtime_assets/1` once in the root layout.
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
  def update(%{filament_msg: msg}, socket) do
    {:ok, Filament.LiveView.apply_to_socket(socket, msg)}
  end

  def update(assigns, socket) do
    component = Map.fetch!(assigns, :component)
    props = Filament.LiveView.extract_props(assigns, component)

    {tree, rendered, pending_effects} =
      case socket.assigns._filament_tree do
        %{"root" => %{component: ^component}} = tree ->
          Reconciler.update(tree, "root", props, owner_pid: self(), target: Filament.Web)

        tree ->
          if tree, do: Reconciler.unmount(tree)
          sources = if Phoenix.LiveView.connected?(socket), do: :subscribe, else: :current
          Reconciler.mount(component, props, owner_pid: self(), target: Filament.Web, sources: sources)
      end

    {:ok, Filament.LiveView.assign_render(socket, tree, rendered, pending_effects)}
  end

  @impl true
  def handle_event("filament:" <> ref, params, socket) do
    Filament.LiveView.dispatch_filament_event(ref, params, socket)
  end

  @impl true
  def render(assigns), do: Filament.LiveView.view(assigns)
end
