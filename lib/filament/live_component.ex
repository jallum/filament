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
  def render(assigns) do
    assigns._filament_rendered
  end
end
