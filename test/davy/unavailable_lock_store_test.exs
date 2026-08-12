defmodule Davy.UnavailableLockStoreTest do
  @moduledoc """
  A lock store that cannot answer must not be mistaken for one reporting
  "no locks held". Every method that consults the store reports the store's
  own status instead of falling through to a lock decision.
  """

  # The InMemory backend is a single named ETS table that `start/0` recreates,
  # so this cannot run concurrently with the other suites that use it.
  use ExUnit.Case, async: false

  alias Davy.Backend.InMemory
  alias Davy.Test.UnavailableLockStore

  @lock_body """
  <?xml version="1.0" encoding="utf-8"?>
  <D:lockinfo xmlns:D="DAV:">
    <D:lockscope><D:exclusive/></D:lockscope>
    <D:locktype><D:write/></D:locktype>
  </D:lockinfo>
  """

  setup do
    InMemory.start()

    {:ok,
     opts: Davy.Plug.init(backend: InMemory, lock_store: UnavailableLockStore),
     working: Davy.Plug.init(backend: InMemory)}
  end

  defp call(conn, opts), do: Davy.Plug.call(conn, opts)
  defp conn(method, path), do: Plug.Test.conn(method, path)
  defp conn(method, path, body), do: Plug.Test.conn(method, path, body)

  defp xml(conn), do: Plug.Conn.put_req_header(conn, "content-type", "application/xml")

  describe "LOCK" do
    test "returns 503 rather than 423 when the store is unreachable", %{opts: opts} do
      resp = conn(:lock, "/test.txt", @lock_body) |> xml() |> call(opts)

      assert resp.status == 503
      assert resp.resp_body == "Lock store unreachable"
    end

    test "returns 503 when refreshing a lock", %{opts: opts} do
      resp =
        conn(:lock, "/test.txt")
        |> Plug.Conn.put_req_header("if", "(<opaquelocktoken:some-token>)")
        |> call(opts)

      assert resp.status == 503
    end
  end

  describe "UNLOCK" do
    test "returns 503 rather than 409", %{opts: opts} do
      resp =
        conn(:unlock, "/test.txt")
        |> Plug.Conn.put_req_header("lock-token", "<opaquelocktoken:some-token>")
        |> call(opts)

      assert resp.status == 503
    end
  end

  describe "write methods" do
    test "PUT returns 503 rather than writing", %{opts: opts} do
      resp = conn(:put, "/test.txt", "data") |> call(opts)

      assert resp.status == 503
    end

    test "PUT does not reach the backend", %{opts: opts, working: working} do
      conn(:put, "/test.txt", "data") |> call(opts)

      assert conn(:get, "/test.txt") |> call(working) |> Map.get(:status) == 404
    end

    test "DELETE returns 503", %{opts: opts} do
      resp = conn(:delete, "/test.txt") |> call(opts)

      assert resp.status == 503
    end

    test "MKCOL returns 503", %{opts: opts} do
      resp = conn(:mkcol, "/newdir") |> call(opts)

      assert resp.status == 503
    end

    test "PROPPATCH returns 503", %{opts: opts} do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propertyupdate xmlns:D="DAV:">
        <D:set><D:prop><X:foo xmlns:X="urn:x">bar</X:foo></D:prop></D:set>
      </D:propertyupdate>
      """

      resp = conn(:proppatch, "/test.txt", body) |> xml() |> call(opts)

      assert resp.status == 503
    end

    test "COPY returns 503", %{opts: opts} do
      resp =
        conn(:copy, "/test.txt")
        |> Plug.Conn.put_req_header("destination", "/copy.txt")
        |> call(opts)

      assert resp.status == 503
    end

    test "MOVE returns 503", %{opts: opts} do
      resp =
        conn(:move, "/test.txt")
        |> Plug.Conn.put_req_header("destination", "/moved.txt")
        |> call(opts)

      assert resp.status == 503
    end
  end

  describe "PROPFIND" do
    test "reports lockdiscovery as unavailable without failing the listing", %{opts: opts} do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:">
        <D:prop><D:resourcetype/><D:lockdiscovery/></D:prop>
      </D:propfind>
      """

      resp = conn(:propfind, "/", body) |> xml() |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "HTTP/1.1 503 Service Unavailable"
      assert resp.resp_body =~ "HTTP/1.1 200 OK"
      assert resp.resp_body =~ "lockdiscovery"
    end

    test "does not consult the store when lockdiscovery is not requested", %{opts: opts} do
      body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:">
        <D:prop><D:resourcetype/></D:prop>
      </D:propfind>
      """

      resp = conn(:propfind, "/", body) |> xml() |> call(opts)

      assert resp.status == 207
      refute resp.resp_body =~ "503"
    end

    test "allprop reports lockdiscovery as unavailable", %{opts: opts} do
      resp = conn(:propfind, "/", "") |> xml() |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "HTTP/1.1 503 Service Unavailable"
      assert resp.resp_body =~ "resourcetype"
    end
  end
end
