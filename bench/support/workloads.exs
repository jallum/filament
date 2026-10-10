defmodule Filament.Bench.Workloads do
  @moduledoc false
  alias Filament.Bench.Compat
  alias Filament.Bench.Rows
  alias Filament.Bench.Store
  alias Filament.Bench.ValueRows
  alias Filament.Reconciler
  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveView.Socket

  @jobs ~w(render/mount render/unchanged render/leaf_state keyed/append keyed/prepend keyed/reverse keyed/move keyed/remove_half keyed/clear reactivity/changed reactivity/unchanged)
  def jobs, do: @jobs

  def setup(job, size) do
    reactive? = String.starts_with?(job, "reactivity/")
    server = if reactive?, do: elem(Store.start_link(), 1)
    items = Enum.to_list(1..size)
    props = if reactive?, do: %{items: items, server: server}, else: %{items: items}
    component = if reactive?, do: ValueRows, else: Rows
    socket = %Socket{assigns: %{__changed__: %{}}, private: %{live_temp: %{}}}

    input = %{
      job: job,
      size: size,
      server: server,
      props: props,
      component: component,
      socket: socket,
      tree: nil,
      client: %{},
      rendered: nil,
      prints: Diff.new_fingerprints(),
      components: Diff.new_components()
    }

    if job == "render/mount" do
      input
    else
      {tree, output, []} = Reconciler.mount(component, props, Compat.render_options())

      {tree, output} = prepare_move(job, tree, output, props, size)

      rendered = Compat.rendered(output)
      {initial_diff, prints, components} = Diff.render(socket, rendered, input.prints, input.components)

      %{
        input
        | tree: tree,
          rendered: rendered,
          prints: prints,
          components: components,
          client: Phoenix.LiveViewTest.Diff.merge_diff(%{}, initial_diff)
      }
    end
  end

  defp prepare_move("keyed/move", tree, _output, props, size) do
    {id, _leaf} = Enum.find(tree, fn {_, fiber} -> fiber.props[:id] == size end)
    tree = Compat.put_state(tree, id, 0, size + 1)
    {tree, output, []} = Reconciler.update(tree, "root", props, Compat.render_options())
    {tree, output}
  end

  defp prepare_move(_job, tree, output, _props, _size), do: {tree, output}

  def run(%{job: "render/mount"} = input) do
    {tree, output, []} = Reconciler.mount(input.component, input.props, Compat.render_options())
    finish(input, tree, output, input.props.items, 0, 0)
  end

  def run(%{job: "render/leaf_state"} = input) do
    {_id, leaf} = Enum.find(input.tree, fn {_, fiber} -> fiber.props[:id] == input.size end)
    :ok = Compat.setter(leaf.hook_slots[0]).(-1)

    receive do
      message when elem(message, 0) == :filament_set_state ->
        value = elem(message, tuple_size(message) - 1)
        tree = Compat.put_state(input.tree, elem(message, 1), elem(message, 2), value)
        update(input, tree, input.props, 1, 1)
    after
      5_000 -> raise "missing state update"
    end
  end

  def run(%{job: "reactivity/" <> change} = input) do
    value = if change == "changed", do: 1, else: 0
    :ok = GenServer.call(input.server, {:write, value})
    {tree, messages, updates} = Compat.drain(input.tree)

    if updates == 0 do
      result(input, tree, input.rendered, %{}, input.props.items, messages, updates)
    else
      update(input, tree, input.props, messages, updates)
    end
  end

  def run(input) do
    items = next_items(input.job, input.props.items, input.size)
    update(input, input.tree, %{input.props | items: items}, 0, 0)
  end

  defp next_items("render/unchanged", items, _), do: items
  defp next_items("keyed/append", items, n), do: items ++ [n + 1]
  defp next_items("keyed/prepend", items, _), do: [0 | items]
  defp next_items("keyed/move", items, _), do: [List.last(items) | Enum.drop(items, -1)]
  defp next_items("keyed/reverse", items, _), do: Enum.reverse(items)
  defp next_items("keyed/remove_half", items, n), do: Enum.take(items, div(n, 2))
  defp next_items("keyed/clear", _, _), do: []

  defp update(input, tree, props, messages, updates) do
    {tree, output, []} = Reconciler.update(tree, "root", props, Compat.render_options())
    finish(input, tree, output, props.items, messages, updates)
  end

  defp finish(input, tree, output, items, messages, updates) do
    rendered = Compat.rendered(output)
    {diff, _prints, _components} = Diff.render(input.socket, rendered, input.prints, input.components)
    result(input, tree, rendered, diff, items, messages, updates)
  end

  defp result(input, tree, rendered, diff, items, messages, updates) do
    %{
      input: input,
      tree: tree,
      rendered: rendered,
      items: items,
      diff: diff,
      wire: Jason.encode_to_iodata!(diff),
      messages: messages,
      updates: updates
    }
  end

  # These checks are run before timing and in Benchee's excluded after_each hook.
  def verify(result) do
    input = result.input
    html = result.rendered |> Safe.to_iodata() |> IO.iodata_to_binary()

    client_html =
      input.client |> Phoenix.LiveViewTest.Diff.merge_diff(result.diff) |> Diff.to_iodata() |> IO.iodata_to_binary()

    ensure(client_html == html, "diff reconstructs the complete rendered HTML")
    rows = html |> Floki.parse_fragment!() |> Floki.find("li")
    ids = Enum.map(rows, fn row -> row |> Floki.attribute("data-id") |> hd() |> String.to_integer() end)
    ensure(ids == result.items, "row identity/order")
    ensure(map_size(result.tree) == length(result.items) + 1, "fiber count")
    values = Enum.map(rows, fn row -> row |> Floki.text() |> String.trim() |> String.to_integer() end)
    ensure(values == expected_values(input, result.items), "rendered values")
    if input.tree, do: verify_retained_fibers(input.tree, result.tree)

    if input.server do
      expected = if input.job == "reactivity/changed", do: input.size, else: 0
      ensure(result.updates == expected, "delivered update count")
      ensure(result.messages == if(expected == 0, do: 0, else: 1), "owner message count")
      ensure(GenServer.call(input.server, :subscription_count) == input.size, "subscription count")
    end

    %{
      diff_bytes: IO.iodata_length(result.wire),
      html_bytes: byte_size(html),
      fibers: map_size(result.tree),
      messages: result.messages,
      updates: result.updates
    }
  end

  defp expected_values(%{job: "reactivity/changed"}, items), do: Enum.map(items, fn _ -> 1 end)
  defp expected_values(%{job: "reactivity/unchanged"}, items), do: Enum.map(items, fn _ -> 0 end)
  defp expected_values(%{job: "render/leaf_state", size: n}, items), do: Enum.map(items, &if(&1 == n, do: -1, else: &1))
  defp expected_values(%{job: "keyed/move", size: n}, items), do: Enum.map(items, &if(&1 == n, do: n + 1, else: &1))
  defp expected_values(_, items), do: items

  defp verify_retained_fibers(old, new) do
    old_ids = Map.new(old, fn {id, fiber} -> {fiber.props[:id], id} end)

    Enum.each(new, fn {id, fiber} ->
      case Map.fetch(old_ids, fiber.props[:id]) do
        {:ok, previous_id} -> ensure(id == previous_id, "retained keyed fiber identity")
        :error -> :ok
      end
    end)
  end

  def cleanup(result) do
    Reconciler.unmount(result.tree, owner_pid: self())

    if result.input.server do
      # This synchronous call also fences main's asynchronous unsubscribe casts.
      ensure(GenServer.call(result.input.server, :subscription_count) == 0, "subscription cleanup")
      GenServer.stop(result.input.server)
    end

    {_tree, messages, _} = Compat.drain(%{})
    ensure(messages == 0, "leftover mailbox traffic")
    :ok
  end

  defp ensure(true, _), do: :ok
  defp ensure(false, label), do: raise("benchmark correctness check failed: #{label}")

  def check_and_cleanup(result) do
    verify(result)
  after
    cleanup(result)
  end

  # Separate diagnostic, not part of Benchee's caller-process allocation metric.
  def server_resources(input) do
    if input.server do
      Map.new(Process.info(input.server, [:memory, :reductions]))
    end
  end
end
