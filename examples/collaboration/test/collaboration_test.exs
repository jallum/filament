defmodule Collaboration.Test do
  use ExUnit.Case, async: true
  import Filament.Test

  setup do
    start_supervised!({Registry, keys: :unique, name: Collaboration.Registry})
    :ok
  end

  # ── Rung 1: DocumentServer ───────────────────────────────────────────────────

  describe "Collaboration.DocumentServer" do
    test "lock acquired by first requester" do
      server = start_supervised!(
        {Collaboration.DocumentServer, [doc_id: "test-doc-#{:erlang.unique_integer()}"]},
        id: make_ref()
      )

      assert Collaboration.DocumentServer.acquire_lock(server, self()) == {:ok, :lock_token}
    end

    test "lock rejected when already held" do
      server = start_supervised!(
        {Collaboration.DocumentServer, [doc_id: "test-doc-#{:erlang.unique_integer()}"]},
        id: make_ref()
      )

      {:ok, _token} = Collaboration.DocumentServer.acquire_lock(server, self())

      parent = self()
      spawn(fn ->
        result = Collaboration.DocumentServer.acquire_lock(server, self())
        send(parent, {:lock_result, result})
      end)

      assert_receive {:lock_result, {:error, :locked}}, 1000
    end

    test "release_lock/2 frees the lock" do
      server = start_supervised!(
        {Collaboration.DocumentServer, [doc_id: "test-doc-#{:erlang.unique_integer()}"]},
        id: make_ref()
      )

      {:ok, _token} = Collaboration.DocumentServer.acquire_lock(server, self())
      :ok = Collaboration.DocumentServer.release_lock(server, self())

      assert Collaboration.DocumentServer.acquire_lock(server, self()) == {:ok, :lock_token}
    end

    test "presence count reflects subscriber count" do
      server = start_supervised!(
        {Collaboration.DocumentServer, [doc_id: "test-doc-#{:erlang.unique_integer()}"]},
        id: make_ref()
      )

      sub = %Filament.Observable.Subscriber{
        pid: self(),
        fiber_id: :presence_test,
        slot_index: 0,
        project: &Function.identity/1
      }

      {:ok, view1} = Filament.Observable.subscribe(server, nil, sub)
      assert view1.presence == 1
    end
  end

  # ── Rung 2: DocumentEditor component ─────────────────────────────────────────

  describe "DocumentEditor component (rung-2)" do
    test "renders edit button when document is not locked" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      server = start_supervised!({Collaboration.DocumentServer, [doc_id: doc_id]}, id: make_ref())

      {:ok, view} = mount(CollaborationWeb.Components.DocumentEditor, %{server: server, doc_id: doc_id})

      text = render_text(view)
      assert text =~ "Edit"
      refute text =~ "Locked"
    end

    test "renders locked when another user holds the lock" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      server = start_supervised!({Collaboration.DocumentServer, [doc_id: doc_id]}, id: make_ref())

      parent = self()
      other_holder = spawn(fn ->
        result = Collaboration.DocumentServer.acquire_lock(server, self())
        send(parent, {:locked, result})
        receive do: (:stop -> :ok)
      end)

      assert_receive {:locked, {:ok, :lock_token}}, 1000

      {:ok, view} = mount(CollaborationWeb.Components.DocumentEditor, %{server: server, doc_id: doc_id})
      view = Filament.Test.update(view)
      assert render_text(view) =~ "Locked"

      Process.exit(other_holder, :kill)
    end

    test "presence indicator present" do
      doc_id = "edit-test-#{:erlang.unique_integer()}"
      server = start_supervised!({Collaboration.DocumentServer, [doc_id: doc_id]}, id: make_ref())

      {:ok, view} = mount(CollaborationWeb.Components.DocumentEditor, %{server: server, doc_id: doc_id})
      assert render_text(view) =~ "user"
    end
  end
end
