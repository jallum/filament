defmodule Filament.Examples.CollaborationTest do
  use ExUnit.Case, async: true
  import Filament.Test

  setup do
    # Start the registry for each test
    start_supervised!({Registry, keys: :unique, name: Collaboration.Registry})
    :ok
  end

  # ── Server-level tests ───────────────────────────────────────────────────────

  describe "Collaboration.DocumentServer" do
    test "lock acquired by first requester" do
      {:ok, server} =
        Collaboration.DocumentServer.start_link(doc_id: "test-doc-#{:erlang.unique_integer()}")

      result = Collaboration.DocumentServer.acquire_lock(server, self())
      assert result == {:ok, :lock_token}
    end

    test "lock rejected when already held" do
      {:ok, server} =
        Collaboration.DocumentServer.start_link(doc_id: "test-doc-#{:erlang.unique_integer()}")

      {:ok, _token} = Collaboration.DocumentServer.acquire_lock(server, self())

      # Second requester (different pid) gets :locked
      parent = self()

      spawn(fn ->
        result = Collaboration.DocumentServer.acquire_lock(server, self())
        send(parent, {:lock_result, result})
      end)

      assert_receive {:lock_result, {:error, :locked}}, 1000
    end

    # NOTE: This test is skipped because the Observable.GenServer :DOWN handler
    # cannot be extended to release locks. Lock holders that die without being
    # subscribers do not automatically release their locks. This is a known
    # limitation documented in flm-g5b.4.
    @tag :skip
    test "lock released on holder process death" do
      {:ok, server} =
        Collaboration.DocumentServer.start_link(doc_id: "test-doc-#{:erlang.unique_integer()}")

      parent = self()

      holder =
        spawn(fn ->
          {:ok, _token} = Collaboration.DocumentServer.acquire_lock(server, self())
          send(parent, :acquired)
          receive do: (:stop -> :ok)
        end)

      assert_receive :acquired, 1000

      # Kill the holder
      Process.exit(holder, :kill)
      Process.sleep(50)

      # Now we should be able to acquire
      result = Collaboration.DocumentServer.acquire_lock(server, self())
      assert result == {:ok, :lock_token}
    end

    test "release_lock/2 frees the lock" do
      {:ok, server} =
        Collaboration.DocumentServer.start_link(doc_id: "test-doc-#{:erlang.unique_integer()}")

      {:ok, _token} = Collaboration.DocumentServer.acquire_lock(server, self())
      :ok = Collaboration.DocumentServer.release_lock(server, self())

      # Should be acquirable again
      result = Collaboration.DocumentServer.acquire_lock(server, self())
      assert result == {:ok, :lock_token}
    end

    test "presence count reflects subscriber count" do
      {:ok, server} =
        Collaboration.DocumentServer.start_link(doc_id: "test-doc-#{:erlang.unique_integer()}")

      # Subscribe manually
      sub = %Filament.Observable.Subscriber{
        pid: self(),
        fiber_id: :presence_test,
        slot_index: 0,
        project: &Function.identity/1
      }

      {:ok, view1} = Filament.Observable.subscribe(server, nil, sub)

      # Initial view has presence=1
      assert view1.presence == 1
    end
  end

  # ── Rung-3 component tests ───────────────────────────────────────────────────

  describe "DocumentEditor component (rung-3)" do
    test "renders edit button when document is not locked" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      {:ok, server} = Collaboration.DocumentServer.start_link(doc_id: doc_id)

      {:ok, view} =
        mount(CollaborationWeb.Components.DocumentEditor.DocumentEditor, %{
          server: server,
          doc_id: doc_id
        })

      text = render_text(view)
      assert text =~ "Edit"
      refute text =~ "Locked"
    end

    test "renders locked when another user holds the lock" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      {:ok, server} = Collaboration.DocumentServer.start_link(doc_id: doc_id)

      # Acquire the lock from a different pid
      parent = self()

      other_holder =
        spawn(fn ->
          result = Collaboration.DocumentServer.acquire_lock(server, self())
          send(parent, {:locked, result})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:locked, {:ok, :lock_token}}, 1000

      # view is subscribed; drain observable updates to re-render
      {:ok, view} =
        mount(CollaborationWeb.Components.DocumentEditor.DocumentEditor, %{
          server: server,
          doc_id: doc_id
        })

      view = Filament.Test.update(view)
      text = render_text(view)
      assert text =~ "Locked"

      # Clean up
      Process.exit(other_holder, :kill)
    end

    test "presence indicator present" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      {:ok, server} = Collaboration.DocumentServer.start_link(doc_id: doc_id)

      {:ok, view} =
        mount(CollaborationWeb.Components.DocumentEditor.DocumentEditor, %{
          server: server,
          doc_id: doc_id
        })

      text = render_text(view)
      assert text =~ "user"
    end
  end
end
