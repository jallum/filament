Code.require_file("../../../bench/support/latest_delivery.exs", __DIR__)

defmodule Filament.Observable.LatestDeliveryProofTest do
  use ExUnit.Case, async: true

  alias Filament.Bench.LatestDelivery

  defp owner do
    pid = spawn(fn -> owner_loop() end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp owner_loop do
    receive do
      {:run, caller, ref, function} ->
        send(caller, {ref, function.()})
        owner_loop()
    end
  end

  defp run(pid, function) do
    ref = make_ref()
    send(pid, {:run, self(), ref, function})

    receive do
      {^ref, result} -> result
    after
      5_000 -> flunk("owner did not respond")
    end
  end

  defp take(pid) do
    run(pid, fn ->
      receive do
        {:latest_delivery, server, token, values} -> {server, token, values}
      after
        0 -> :empty
      end
    end)
  end

  defp ack(pid, server, token) do
    run(pid, fn ->
      LatestDelivery.acknowledge(server, token)
      LatestDelivery.status(server)
    end)
  end

  test "a fast producer queues one batch per owner, then delivers its final value" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()

    for key <- 1..1000 do
      assert {:ok, _, 0} = run(slow, fn -> LatestDelivery.subscribe(server, key, &Function.identity/1) end)
    end

    for value <- 1..100, do: LatestDelivery.write(server, value)
    assert {:message_queue_len, 1} = Process.info(slow, :message_queue_len)
    {^server, first, values} = take(slow)
    assert map_size(values) == 1000
    assert Enum.all?(values, fn {_key, {_generation, value}} -> value == 1 end)
    ack(slow, server, first)
    assert {:message_queue_len, 1} = Process.info(slow, :message_queue_len)
    {^server, final, values} = take(slow)
    assert Enum.all?(values, fn {_key, {_generation, value}} -> value == 100 end)
    ack(slow, server, final)
    assert :empty = take(slow)
    assert %{^slow => %{cells: 1000, in_flight: false}} = LatestDelivery.status(server)
  end

  test "duplicate, foreign and old acknowledgments cannot clear a newer batch" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()
    foreign = owner()
    {:ok, _, 0} = run(slow, fn -> LatestDelivery.subscribe(server, :value, &Function.identity/1) end)
    LatestDelivery.write(server, 1)
    {^server, first, _} = take(slow)
    LatestDelivery.write(server, 2)
    ack(foreign, server, first)
    assert :empty = take(slow)
    ack(slow, server, first)
    {^server, second, _} = take(slow)
    LatestDelivery.write(server, 3)
    ack(slow, server, first)
    ack(slow, server, make_ref())
    assert :empty = take(slow)
    ack(slow, server, second)
    assert {^server, third, %{value: {_, 3}}} = take(slow)
    ack(slow, server, third)
    assert :empty = take(slow)
  end

  test "replacement generations and unsubscribe/resubscribe keep one owner batch" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()
    {:ok, old_generation, 0} = run(slow, fn -> LatestDelivery.subscribe(server, :value, &Function.identity/1) end)
    LatestDelivery.write(server, 1)

    for value <- 2..20 do
      run(slow, fn -> LatestDelivery.unsubscribe(server, :value) end)
      run(slow, fn -> LatestDelivery.subscribe(server, :value, &Function.identity/1) end)
      LatestDelivery.write(server, value)
    end

    assert {:message_queue_len, 1} = Process.info(slow, :message_queue_len)
    {^server, first, %{value: {^old_generation, 1}}} = take(slow)
    {:ok, generation, 200} = run(slow, fn -> LatestDelivery.subscribe(server, :value, &(&1 * 10)) end)
    # The replacement's synchronous snapshot is 200, not 20.
    assert is_reference(generation)
    LatestDelivery.write(server, 21)
    ack(slow, server, first)
    assert {^server, second, %{value: {^generation, 210}}} = take(slow)
    LatestDelivery.write(server, 22)
    ack(slow, server, first)
    assert :empty = take(slow)
    ack(slow, server, second)
    assert {^server, third, %{value: {^generation, 220}}} = take(slow)
    run(slow, fn -> LatestDelivery.unsubscribe(server, :value) end)
    ack(slow, server, third)
    assert LatestDelivery.status(server) == %{}
  end

  test "coalescing respects projected equality, strict equality and a return to the sent value" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()
    {:ok, generation, 0} = run(slow, fn -> LatestDelivery.subscribe(server, :value, &Function.identity/1) end)
    LatestDelivery.write(server, 0.0)
    assert {^server, token, %{value: {^generation, value}}} = take(slow)
    assert value === 0.0
    LatestDelivery.write(server, 10)
    LatestDelivery.write(server, 0.0)
    ack(slow, server, token)
    assert :empty = take(slow)
    LatestDelivery.write(server, 0)
    assert {^server, token, %{value: {^generation, 0}}} = take(slow)
    ack(slow, server, token)
    {:ok, _, 0} = run(slow, fn -> LatestDelivery.subscribe(server, :value, &rem(&1, 2)) end)
    for value <- [2, 4, 6], do: LatestDelivery.write(server, value)
    assert :empty = take(slow)
  end

  test "returning to the initial value still delivers a correction, and removed cells stay removed" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()
    {:ok, generation, 0} = run(slow, fn -> LatestDelivery.subscribe(server, :kept, &Function.identity/1) end)
    run(slow, fn -> LatestDelivery.subscribe(server, :removed, &Function.identity/1) end)
    LatestDelivery.write(server, 1)
    {^server, first, initial} = take(slow)
    assert map_size(initial) == 2
    run(slow, fn -> LatestDelivery.unsubscribe(server, :removed) end)
    LatestDelivery.write(server, 0)
    ack(slow, server, first)
    assert {^server, final, %{kept: {^generation, 0}} = values} = take(slow)
    assert map_size(values) == 1
    ack(slow, server, final)
    assert :empty = take(slow)
  end

  test "slow owners do not block healthy ones, and owner death releases pending state" do
    server = start_supervised!({LatestDelivery, 0})
    slow = owner()
    healthy = owner()
    for pid <- [slow, healthy], do: run(pid, fn -> LatestDelivery.subscribe(server, :value, &Function.identity/1) end)

    for value <- 1..10 do
      LatestDelivery.write(server, value)
      assert {^server, token, %{value: {_, ^value}}} = take(healthy)
      ack(healthy, server, token)
    end

    assert {:message_queue_len, 1} = Process.info(slow, :message_queue_len)
    ref = Process.monitor(slow)
    Process.exit(slow, :kill)
    assert_receive {:DOWN, ^ref, :process, ^slow, :killed}
    # Fence the server's independently delivered DOWN with a bounded retry.
    assert eventually(fn -> not Map.has_key?(LatestDelivery.status(server), slow) end)
    LatestDelivery.write(server, 11)
    assert {^server, token, %{value: {_, 11}}} = take(healthy)
    ack(healthy, server, token)
  end

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(1)
          eventually(check, attempts - 1)
        )
  end
end
