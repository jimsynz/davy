defmodule Davy.TelemetryTest do
  # async: false — `:telemetry` handlers are global and InMemory.start/0
  # recreates a shared ETS table, both of which race with other test files.
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Davy.Backend.InMemory
  alias Davy.LockStore

  setup do
    InMemory.start()
    LockStore.ETS.reset()
    opts = Davy.Plug.init(backend: InMemory)
    {:ok, opts: opts}
  end

  defp call(conn, opts), do: Davy.Plug.call(conn, opts)
  defp conn(method, path), do: Plug.Test.conn(method, path)
  defp conn(method, path, body), do: Plug.Test.conn(method, path, body)

  defp attach(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit_detach(ref)
    ref
  end

  defp on_exit_detach(ref) do
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(ref) end)
  end

  describe "[:davy, :request, ...]" do
    test "emits start and stop for a handled request", %{opts: opts} do
      attach([[:davy, :request, :start], [:davy, :request, :stop]])

      conn(:options, "/") |> call(opts)

      assert_received {[:davy, :request, :start], _ref, measurements, start_meta}
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
      assert start_meta.method == "OPTIONS"
      assert start_meta.path == []
      assert %Plug.Conn{} = start_meta.conn

      assert_received {[:davy, :request, :stop], _ref, stop_measurements, stop_meta}
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration >= 0
      assert stop_meta.method == "OPTIONS"
      assert stop_meta.status == 200
      assert %Plug.Conn{} = stop_meta.conn
    end

    test "no request span is emitted when authentication fails", %{opts: opts} do
      attach([[:davy, :request, :start], [:davy, :request, :stop]])

      opts = %{opts | backend: Davy.TelemetryTest.UnauthedBackend}
      resp = conn(:get, "/anything") |> call(opts)

      assert resp.status == 401
      refute_received {[:davy, :request, :start], _, _, _}
    end
  end

  describe "[:davy, :backend, ...]" do
    test "wraps resolve + put_content for PUT", %{opts: opts} do
      attach([
        [:davy, :backend, :resolve, :stop],
        [:davy, :backend, :put_content, :stop]
      ])

      conn(:put, "/hello.txt", "hi")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      assert_received {[:davy, :backend, :resolve, :stop], _ref, _m, resolve_meta}
      assert resolve_meta.backend == InMemory
      assert resolve_meta.operation == :resolve
      assert resolve_meta.path == ["hello.txt"]
      assert resolve_meta.result == {:error, :not_found}

      assert_received {[:davy, :backend, :put_content, :stop], _ref, pm, put_meta}
      assert pm.duration >= 0
      assert put_meta.backend == InMemory
      assert put_meta.path == ["hello.txt"]
      assert put_meta.result == :ok
    end

    test "wraps copy with source/dest metadata", %{opts: opts} do
      conn(:put, "/src.txt", "payload")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      attach([[:davy, :backend, :copy, :stop]])

      conn(:copy, "/src.txt")
      |> put_req_header("destination", "/dst.txt")
      |> call(opts)

      assert_received {[:davy, :backend, :copy, :stop], _ref, _m, meta}
      assert meta.operation == :copy
      assert meta.source_path == ["src.txt"]
      assert meta.dest_path == ["dst.txt"]
      assert meta.overwrite == true
      assert meta.result == :ok
    end

    test "wraps authenticate", %{opts: opts} do
      attach([[:davy, :backend, :authenticate, :stop]])

      conn(:options, "/") |> call(opts)

      assert_received {[:davy, :backend, :authenticate, :stop], _ref, _m, meta}
      assert meta.backend == InMemory
      assert meta.operation == :authenticate
      assert %Plug.Conn{} = meta.conn
      assert meta.result == :ok
    end

    test "emits :exception when a backend raises", %{opts: opts} do
      opts = %{opts | backend: Davy.TelemetryTest.RaisingBackend}
      attach([[:davy, :backend, :resolve, :exception]])

      assert_raise RuntimeError, fn -> conn(:get, "/any") |> call(opts) end

      assert_received {[:davy, :backend, :resolve, :exception], _ref, measurements, meta}
      assert is_integer(measurements.duration)
      assert meta.kind == :error
      assert %RuntimeError{} = meta.reason
      assert is_list(meta.stacktrace)
    end
  end

  describe "[:davy, :lock_store, ...]" do
    test "emits lock and unlock spans", %{opts: opts} do
      attach([
        [:davy, :lock_store, :lock, :stop],
        [:davy, :lock_store, :unlock, :stop]
      ])

      lock_body = """
      <?xml version="1.0" encoding="utf-8" ?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
      </D:lockinfo>
      """

      lock_resp =
        conn(:lock, "/locked.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert lock_resp.status in [200, 201]

      assert_received {[:davy, :lock_store, :lock, :stop], _ref, _m, lock_meta}
      assert lock_meta.lock_store == LockStore.ETS
      assert lock_meta.operation == :lock
      assert lock_meta.path == ["locked.txt"]
      assert lock_meta.scope == :exclusive
      assert lock_meta.result == :ok

      [token] =
        Regex.run(~r/<opaquelocktoken:([^>]+)>/, hd(get_resp_header(lock_resp, "lock-token")),
          capture: :all_but_first
        )

      conn(:unlock, "/locked.txt")
      |> put_req_header("lock-token", "<opaquelocktoken:#{token}>")
      |> call(opts)

      assert_received {[:davy, :lock_store, :unlock, :stop], _ref, _m, unlock_meta}
      assert unlock_meta.operation == :unlock
      assert unlock_meta.token == token
      assert unlock_meta.result == :ok
    end

    test "emits get_locks_covering when checking write locks", %{opts: opts} do
      attach([[:davy, :lock_store, :get_locks_covering, :stop]])

      conn(:put, "/a.txt", "x")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      assert_received {[:davy, :lock_store, :get_locks_covering, :stop], _ref, _m, meta}
      assert meta.operation == :get_locks_covering
      assert meta.path == ["a.txt"]
    end
  end

  defmodule UnauthedBackend do
    @behaviour Davy.Backend

    @impl true
    def authenticate(_conn), do: {:error, :unauthorized}

    @impl true
    def resolve(_, _), do: raise("unreachable")
    @impl true
    def get_properties(_, _, _), do: raise("unreachable")
    @impl true
    def set_properties(_, _, _), do: raise("unreachable")
    @impl true
    def get_content(_, _, _), do: raise("unreachable")
    @impl true
    def put_content(_, _, _, _), do: raise("unreachable")
    @impl true
    def delete(_, _), do: raise("unreachable")
    @impl true
    def copy(_, _, _, _), do: raise("unreachable")
    @impl true
    def move(_, _, _, _), do: raise("unreachable")
    @impl true
    def create_collection(_, _), do: raise("unreachable")
    @impl true
    def get_members(_, _), do: raise("unreachable")
  end

  defmodule RaisingBackend do
    @behaviour Davy.Backend

    @impl true
    def authenticate(_conn), do: {:ok, %{}}

    @impl true
    def resolve(_auth, _path), do: raise("boom")

    @impl true
    def get_properties(_, _, _), do: raise("unreachable")
    @impl true
    def set_properties(_, _, _), do: raise("unreachable")
    @impl true
    def get_content(_, _, _), do: raise("unreachable")
    @impl true
    def put_content(_, _, _, _), do: raise("unreachable")
    @impl true
    def delete(_, _), do: raise("unreachable")
    @impl true
    def copy(_, _, _, _), do: raise("unreachable")
    @impl true
    def move(_, _, _, _), do: raise("unreachable")
    @impl true
    def create_collection(_, _), do: raise("unreachable")
    @impl true
    def get_members(_, _), do: raise("unreachable")
  end
end
