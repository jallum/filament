defmodule Filament.Test do
  @moduledoc """
  Rung 2 test API for Filament components.

  Mount a component in isolation, drive it with simulated events, assert on rendered HTML.
  No WebSocket required.

  Example:

      import Filament.Test

      {:ok, stub} = Filament.Test.Stub.start(fn _ -> %{count: 0} end)

      {:ok, view} = mount(Counter, %{server: stub})
      assert render_text(view) =~ "Count: 0"

      {:ok, view} = click(view, "button")
      assert render_text(view) =~ "Count: 1"
  """

  alias Filament.Test.Stub
  alias Phoenix.HTML.Engine, as: HTMLEngine
  alias Phoenix.LiveView.Rendered

  @compile {:no_warn_undefined, [Floki]}

  defstruct [
    :component,
    :props,
    :fiber_tree,
    :rendered,
    :rendered_html,
    :owner_pid,
    :stubs
  ]

  @type t :: %__MODULE__{
          component: module(),
          props: map(),
          fiber_tree: map(),
          rendered: Rendered.t(),
          rendered_html: String.t(),
          owner_pid: pid(),
          stubs: %{term() => pid()}
        }

  # ── Floki availability check ──────────────────────────────────────────────

  defp require_floki! do
    Code.ensure_loaded?(Floki) ||
      raise """
      Filament.Test requires :floki. Add to your mix.exs:

          {:floki, "~> 0.38", only: :test}
      """
  end

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Mount `component` with `props`. Returns `{:ok, view}` or `{:error, reason}`.

  Options:
    * `:stub` — list of `{server_identity, stub_fn}` pairs (see `Filament.Test.Stub`).
      Example: `stub: [{CartServer, fn _req -> %{items: []} end}]`
  """
  @spec mount(component :: module(), props :: map(), opts :: keyword()) ::
          {:ok, t()} | {:error, term()}
  def mount(component, props, opts \\ []) do
    stub_specs = Keyword.get(opts, :stub, [])
    {stubs_map, _pids} = Stub.build(stub_specs)

    owner_pid = self()

    {tree, rendered, pending_effects} =
      Filament.Reconciler.mount(component, props,
        owner_pid: owner_pid,
        observable_stubs: stubs_map
      )

    tree = run_effects(tree, pending_effects)

    html = rendered_to_string(rendered)

    view = %__MODULE__{
      component: component,
      props: props,
      fiber_tree: tree,
      rendered: rendered,
      rendered_html: html,
      owner_pid: owner_pid,
      stubs: stubs_map
    }

    {:ok, view}
  end

  @doc "Return the rendered HTML as a plain string (with HTML tags stripped)."
  @spec render_text(t()) :: String.t()
  def render_text(%__MODULE__{rendered_html: html}) do
    require_floki!()

    html
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  @doc """
  Return true if the element matching `selector` has CSS class `class_name`.
  Raises if selector matches no elements.
  """
  @spec has_class?(t(), selector :: String.t(), class_name :: String.t()) :: boolean()
  def has_class?(%__MODULE__{rendered_html: html}, selector, class_name) do
    require_floki!()

    html
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
    |> case do
      [] ->
        raise "has_class?: no element matched selector #{inspect(selector)}"

      elements ->
        Enum.any?(elements, fn el ->
          class_attr = el |> Floki.attribute("class") |> List.first() || ""
          class_name in String.split(class_attr, ~r/\s+/, trim: true)
        end)
    end
  end

  @doc """
  Simulate a click on the element matching `selector`.
  Finds the `phx-click` attribute, dispatches the event handler, flushes resulting
  state updates, and re-renders. Returns `{:ok, updated_view}` or `{:error, reason}`.
  """
  @spec click(t(), selector :: String.t()) :: {:ok, t()} | {:error, term()}
  def click(%__MODULE__{} = view, selector) do
    require_floki!()

    case find_event_ref(view.rendered_html, selector, "phx-click") do
      {:ok, ref} -> dispatch_event(view, ref, %{})
      {:error, _} = err -> err
    end
  end

  @doc """
  Simulate a form submission on the element matching `selector` with `params`.
  Finds the `phx-submit` attribute on the form, dispatches the handler with params,
  flushes state updates, re-renders. Returns `{:ok, updated_view}` or `{:error, reason}`.
  """
  @spec submit(t(), selector :: String.t(), params :: map()) ::
          {:ok, t()} | {:error, term()}
  def submit(%__MODULE__{} = view, selector, params \\ %{}) do
    require_floki!()

    case find_event_ref(view.rendered_html, selector, "phx-submit") do
      {:ok, ref} -> dispatch_event(view, ref, params)
      {:error, _} = err -> err
    end
  end

  @doc """
  Simulate a window keydown event with the given key string and optional modifiers.

  Accepts `ctrl: true`, `shift: true`, `alt: true`, `meta: true` in opts.
  Finds the first element with `phx-hook="FilamentKey"`, dispatches the handler
  with `%{"key" => key, "ctrl" => ..., ...}`, flushes state updates, and re-renders.
  Returns `{:ok, updated_view}` or `{:error, reason}`.
  """
  @spec key_down(t(), key :: String.t(), opts :: keyword()) :: {:ok, t()} | {:error, term()}
  def key_down(%__MODULE__{} = view, key, opts \\ []) do
    require_floki!()

    wires =
      view.rendered_html
      |> Floki.parse_fragment!()
      |> Floki.attribute("[phx-hook=FilamentKey]", "data-filament-wire")

    params = %{
      "key" => key,
      "ctrl" => Keyword.get(opts, :ctrl, false),
      "shift" => Keyword.get(opts, :shift, false),
      "alt" => Keyword.get(opts, :alt, false),
      "meta" => Keyword.get(opts, :meta, false)
    }

    case wires do
      [] -> {:error, :no_window_keydown_handler}
      [wire | _] -> dispatch_event(view, "filament:" <> wire, params)
    end
  end

  @doc """
  Simulate a change event on the element matching `selector` with `params`.
  Finds the `phx-change` attribute, dispatches the handler with params,
  flushes state updates, re-renders. Returns `{:ok, updated_view}` or `{:error, reason}`.
  """
  @spec change(t(), selector :: String.t(), params :: map()) :: {:ok, t()} | {:error, term()}
  def change(%__MODULE__{} = view, selector, params) do
    require_floki!()

    case find_event_ref(view.rendered_html, selector, "phx-change") do
      {:ok, ref} -> dispatch_event(view, ref, params)
      {:error, _} = err -> err
    end
  end

  @doc """
  Simulate a blur event on the element matching `selector`.
  Finds the `phx-blur` attribute, dispatches the handler, flushes state updates,
  re-renders. Returns `{:ok, updated_view}` or `{:error, reason}`.
  """
  @spec blur(t(), selector :: String.t()) :: {:ok, t()} | {:error, term()}
  def blur(%__MODULE__{} = view, selector) do
    require_floki!()

    case find_event_ref(view.rendered_html, selector, "phx-blur") do
      {:ok, ref} -> dispatch_event(view, ref, %{})
      {:error, _} = err -> err
    end
  end

  @doc """
  Simulate an element-scoped keydown event on the element matching `selector`.
  Finds the `phx-keydown` attribute, dispatches the handler with `%{"key" => key}`,
  flushes state updates, re-renders. Returns `{:ok, updated_view}` or `{:error, reason}`.

  For window-level keydown (`on_key`), use `key_down/2` instead.
  """
  @spec keydown(t(), selector :: String.t(), key :: String.t()) :: {:ok, t()} | {:error, term()}
  def keydown(%__MODULE__{} = view, selector, key) do
    require_floki!()

    case find_event_ref(view.rendered_html, selector, "phx-keydown") do
      {:ok, ref} -> dispatch_event(view, ref, %{"key" => key})
      {:error, _} = err -> err
    end
  end

  @doc """
  Drain pending filament messages and re-render the view.
  Useful after pushing to an observable stub from outside the component.
  """
  @spec update(t()) :: t()
  def update(%__MODULE__{} = view) do
    flush_messages(view)
  end

  @doc """
  Assert that `assertion_fn.()` returns a truthy value within `timeout` milliseconds.
  Retries every `interval` ms. Raises `ExUnit.AssertionError` on timeout.

  The assertion function must be a zero-arity function. For assertions that need
  to first call `update/1`, include that call inside the fn and use the returned
  view for the assertion:

      Filament.Test.eventually(fn ->
        view = Filament.Test.update(view)
        render_text(view) =~ "Count: 5"
      end, timeout: 500)
  """
  @spec eventually(assertion_fn :: (-> term()), opts :: keyword()) :: :ok
  def eventually(assertion_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1_000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(assertion_fn, deadline, interval, timeout)
  end

  defp do_eventually(fun, deadline, interval, original_timeout) do
    if fun.() do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise RuntimeError,
          message: "Filament.Test.eventually/2 timed out after #{original_timeout}ms"
      else
        Process.sleep(min(interval, remaining))
        do_eventually(fun, deadline, interval, original_timeout)
      end
    end
  end

  # ── HTML rendering helpers ────────────────────────────────────────────────

  @doc false
  def rendered_to_string(%Rendered{static: static, dynamic: dynamic}) do
    old_ctx = Process.get(:filament_render_context)

    # Set up a minimal context so register_event_handler works during string
    # conversion. The handlers registered here are dummies; the wire refs
    # produced will match the real handlers because both sequences start at 0.
    Process.put(:filament_render_context, %Filament.RenderContext{
      fiber_id: "root",
      fiber_tree: %{},
      hook_index: 0,
      new_hook_slots: %{},
      pending_effects: [],
      event_handler_index: 0,
      new_event_handlers: %{},
      observable_stubs: %{},
      owner_pid: nil
    })

    try do
      parts = dynamic.(false)
      static |> interleave(parts) |> IO.iodata_to_binary()
    after
      if old_ctx do
        Process.put(:filament_render_context, old_ctx)
      else
        Process.delete(:filament_render_context)
      end
    end
  end

  defp interleave([s | statics], [d | dynamics]) do
    [s, part_to_iodata(d) | interleave(statics, dynamics)]
  end

  defp interleave([s], []), do: [s]
  defp interleave([], []), do: []

  defp part_to_iodata(nil), do: ""
  defp part_to_iodata(s) when is_binary(s), do: s
  defp part_to_iodata({:safe, data}), do: data
  defp part_to_iodata(%Rendered{} = r), do: rendered_to_string(r)
  defp part_to_iodata(list) when is_list(list), do: list
  defp part_to_iodata(other), do: HTMLEngine.encode_to_iodata!(other)

  # ── Event dispatch helpers ────────────────────────────────────────────────

  defp find_event_ref(html, selector, attr) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find(selector)
    |> case do
      [] ->
        {:error, {:no_element, selector}}

      elements ->
        case Floki.attribute(elements, attr) do
          [] -> {:error, {:no_attribute, attr, selector}}
          [ref | _] -> {:ok, ref}
        end
    end
  end

  defp dispatch_event(view, "filament:" <> ref, params) do
    case String.split(ref, ":", parts: 2) do
      [fiber_id_str, index_str] ->
        handler_index = String.to_integer(index_str)

        handler =
          Filament.FiberTree.get_event_handler(
            view.fiber_tree,
            fiber_id_str,
            handler_index
          )

        case handler do
          nil ->
            {:error, {:stale_handler, ref}}

          fun when is_function(fun, 0) ->
            fun.()
            {:ok, flush_messages(view)}

          fun when is_function(fun, 1) ->
            fun.(params)
            {:ok, flush_messages(view)}
        end

      _other ->
        {:error, {:bad_ref_format, ref}}
    end
  end

  defp dispatch_event(_view, ref, _params) do
    {:error, {:not_filament_event, ref}}
  end

  defp flush_messages(view) do
    receive do
      {:filament_set_state, fiber_id, slot_index, new_value} ->
        view = apply_hook_slot_update(view, fiber_id, slot_index, new_value)
        flush_messages(view)

      {:filament_observable_updates, updates} ->
        tree = Filament.LiveView.apply_observable_updates(view.fiber_tree, updates)
        flush_messages(%{view | fiber_tree: tree})

      {:filament_observable_resubscribe, fiber_id, slot_index} ->
        view = apply_hook_slot_update(view, fiber_id, slot_index, :needs_resubscribe)
        flush_messages(view)
    after
      0 -> rerender(view)
    end
  end

  defp apply_hook_slot_update(view, fiber_id, slot_index, new_value) do
    tree =
      Filament.FiberTree.update_hook_slot(
        view.fiber_tree,
        fiber_id,
        slot_index,
        fn existing ->
          # Preserve existing setter when updating use_state value
          setter =
            case existing do
              {_, s} when is_function(s, 1) -> s
              _ -> nil
            end

          {new_value, setter}
        end
      )

    %{view | fiber_tree: tree}
  end

  defp rerender(view) do
    {new_tree, new_rendered, pending_effects} =
      Filament.Reconciler.update(
        view.fiber_tree,
        "root",
        view.props,
        owner_pid: view.owner_pid,
        observable_stubs: view.stubs
      )

    new_tree = run_effects(new_tree, pending_effects)
    html = rendered_to_string(new_rendered)

    %{view | fiber_tree: new_tree, rendered: new_rendered, rendered_html: html}
  end

  # ── Effect runner ─────────────────────────────────────────────────────────

  defp run_effects(tree, []), do: tree

  defp run_effects(tree, pending_effects) do
    {new_tree, _count} = Filament.LiveView.apply_effects(pending_effects, tree)
    new_tree
  end
end
