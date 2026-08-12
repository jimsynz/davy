defmodule Davy.PlugTest do
  use ExUnit.Case, async: true

  alias Davy.Backend.InMemory
  alias Davy.LockStore
  alias Davy.Test.StreamingBackend

  setup do
    InMemory.start()
    LockStore.ETS.reset()
    opts = Davy.Plug.init(backend: InMemory)
    {:ok, opts: opts}
  end

  defp call(conn, opts), do: Davy.Plug.call(conn, opts)
  defp conn(method, path), do: Plug.Test.conn(method, path)
  defp conn(method, path, body), do: Plug.Test.conn(method, path, body)

  defp get_range(path, spec, opts) do
    conn(:get, path)
    |> put_req_header("range", spec)
    |> call(opts)
  end

  # --- OPTIONS ---

  describe "OPTIONS" do
    test "returns DAV headers", %{opts: opts} do
      resp = conn(:options, "/") |> call(opts)

      assert resp.status == 200
      assert get_header(resp, "dav") == "1, 2"
      assert get_header(resp, "ms-author-via") == "DAV"
      assert "PROPFIND" in String.split(get_header(resp, "allow"), ", ")
      assert "LOCK" in String.split(get_header(resp, "allow"), ", ")
    end
  end

  # --- PUT + GET ---

  describe "PUT" do
    test "creates a new file", %{opts: opts} do
      resp =
        conn(:put, "/test.txt", "hello world")
        |> put_req_header("content-type", "text/plain")
        |> call(opts)

      assert resp.status == 201
      assert get_header(resp, "etag") != nil
    end

    test "overwrites an existing file", %{opts: opts} do
      conn(:put, "/test.txt", "v1") |> call(opts)
      resp = conn(:put, "/test.txt", "v2") |> call(opts)

      assert resp.status == 204
    end

    test "returns 409 when parent does not exist", %{opts: opts} do
      resp = conn(:put, "/no/such/file.txt", "data") |> call(opts)

      assert resp.status == 409
    end

    test "returns 413 when body exceeds max_buffered_put_bytes", _ do
      InMemory.start()
      LockStore.ETS.reset()
      opts = Davy.Plug.init(backend: InMemory, max_buffered_put_bytes: 1024)

      body = :crypto.strong_rand_bytes(2048)

      resp =
        conn(:put, "/too-big.bin", body)
        |> put_req_header("content-type", "application/octet-stream")
        |> call(opts)

      assert resp.status == 413
    end

    test "accepts a body exactly at the cap", _ do
      InMemory.start()
      LockStore.ETS.reset()
      opts = Davy.Plug.init(backend: InMemory, max_buffered_put_bytes: 1024)

      body = :crypto.strong_rand_bytes(1024)

      resp =
        conn(:put, "/exact.bin", body)
        |> put_req_header("content-type", "application/octet-stream")
        |> call(opts)

      assert resp.status == 201
    end
  end

  describe "PUT (streaming backend)" do
    setup do
      StreamingBackend.start()
      LockStore.ETS.reset()
      opts = Davy.Plug.init(backend: StreamingBackend)
      {:ok, opts: opts}
    end

    test "creates a new file via the streaming callback", %{opts: opts} do
      resp =
        conn(:put, "/streamed.txt", "hello streamed world")
        |> put_req_header("content-type", "text/plain")
        |> call(opts)

      assert resp.status == 201
      segments = StreamingBackend.segments_for(["streamed.txt"])
      assert IO.iodata_to_binary(segments) == "hello streamed world"
    end

    test "feeds the body in bounded slices", %{opts: opts} do
      # 200 KiB body — the 64 KiB slice size should produce 4 segments
      # (3 × 64 KiB + 1 × 8 KiB).
      body = :crypto.strong_rand_bytes(200 * 1024)

      resp =
        conn(:put, "/large.bin", body)
        |> put_req_header("content-type", "application/octet-stream")
        |> call(opts)

      assert resp.status == 201
      segments = StreamingBackend.segments_for(["large.bin"])
      assert IO.iodata_to_binary(segments) == body
      assert length(segments) >= 2

      assert Enum.all?(segments, &(byte_size(&1) <= 64 * 1024)),
             "expected each segment to fit in the 64 KiB slice"
    end

    test "overwrites an existing file via streaming", %{opts: opts} do
      conn(:put, "/over.txt", "v1") |> call(opts)
      resp = conn(:put, "/over.txt", "v2-streamed-content") |> call(opts)

      assert resp.status == 204
    end
  end

  describe "GET" do
    test "returns file content", %{opts: opts} do
      conn(:put, "/test.txt", "hello world")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      resp = conn(:get, "/test.txt") |> call(opts)

      assert resp.status == 200
      assert resp.resp_body == "hello world"
      assert get_header(resp, "content-type") == "text/plain"
      assert get_header(resp, "etag") != nil
    end

    test "returns 404 for missing file", %{opts: opts} do
      resp = conn(:get, "/nonexistent.txt") |> call(opts)

      assert resp.status == 404
    end

    test "returns 405 for collection", %{opts: opts} do
      resp = conn(:get, "/") |> call(opts)

      assert resp.status == 405
    end
  end

  describe "GET with Range" do
    setup %{opts: opts} do
      conn(:put, "/range.txt", "0123456789ABCDEF") |> call(opts)
      :ok
    end

    test "serves a closed range", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=5-9", opts)

      assert resp.status == 206
      assert resp.resp_body == "56789"
      assert get_header(resp, "content-range") == "bytes 5-9/16"
      assert get_header(resp, "content-length") == "5"
      assert get_header(resp, "accept-ranges") == "bytes"
    end

    test "serves an open-ended range", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=10-", opts)

      assert resp.status == 206
      assert resp.resp_body == "ABCDEF"
      assert get_header(resp, "content-range") == "bytes 10-15/16"
    end

    test "serves a suffix range", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=-4", opts)

      assert resp.status == 206
      assert resp.resp_body == "CDEF"
      assert get_header(resp, "content-range") == "bytes 12-15/16"
    end

    test "serves the whole representation when the suffix is longer than it", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=-99", opts)

      assert resp.status == 206
      assert resp.resp_body == "0123456789ABCDEF"
      assert get_header(resp, "content-range") == "bytes 0-15/16"
    end

    test "clamps a range that runs past the end", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=12-99", opts)

      assert resp.status == 206
      assert resp.resp_body == "CDEF"
      assert get_header(resp, "content-range") == "bytes 12-15/16"
    end

    test "returns 416 when the first position is past the end", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=100-200", opts)

      assert resp.status == 416
      assert get_header(resp, "content-range") == "bytes */16"
    end

    test "returns 416 for an open-ended range past the end", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=100-", opts)

      assert resp.status == 416
      assert get_header(resp, "content-range") == "bytes */16"
    end

    test "returns 416 for a zero-length suffix", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=-0", opts)

      assert resp.status == 416
    end

    test "returns 416 for any range on an empty file", %{opts: opts} do
      conn(:put, "/empty.txt", "") |> call(opts)

      assert get_range("/empty.txt", "bytes=0-", opts).status == 416
      assert get_range("/empty.txt", "bytes=-1", opts).status == 416
    end

    test "ignores a range whose last position precedes its first", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=9-5", opts)

      assert resp.status == 200
      assert resp.resp_body == "0123456789ABCDEF"
    end

    test "ignores multi-range requests", %{opts: opts} do
      resp = get_range("/range.txt", "bytes=0-1,5-6", opts)

      assert resp.status == 200
      assert resp.resp_body == "0123456789ABCDEF"
    end

    test "ignores unparseable and unsupported ranges", %{opts: opts} do
      for spec <- ["bytes=", "bytes=-", "bytes=abc-def", "bytes=5", "items=0-1"] do
        assert get_range("/range.txt", spec, opts).status == 200
      end
    end

    test "HEAD reports the range without a body", %{opts: opts} do
      resp =
        conn(:head, "/range.txt")
        |> put_req_header("range", "bytes=5-9")
        |> call(opts)

      assert resp.status == 206
      assert resp.resp_body == ""
      assert get_header(resp, "content-range") == "bytes 5-9/16"
      assert get_header(resp, "content-length") == "5"
    end

    test "HEAD reports 416 for an unsatisfiable range", %{opts: opts} do
      resp =
        conn(:head, "/range.txt")
        |> put_req_header("range", "bytes=100-")
        |> call(opts)

      assert resp.status == 416
      assert resp.resp_body == ""
    end
  end

  describe "GET (streaming backend)" do
    setup do
      StreamingBackend.start()
      opts = Davy.Plug.init(backend: StreamingBackend)
      conn(:put, "/streamed.txt", "0123456789ABCDEF") |> call(opts)
      {:ok, opts: opts}
    end

    test "streams the whole file", %{opts: opts} do
      resp = conn(:get, "/streamed.txt") |> call(opts)

      assert resp.status == 200
      assert resp.resp_body == "0123456789ABCDEF"
    end

    test "streams a resolved range with a matching content-length", %{opts: opts} do
      resp = get_range("/streamed.txt", "bytes=-6", opts)

      assert resp.status == 206
      assert resp.resp_body == "ABCDEF"
      assert get_header(resp, "content-range") == "bytes 10-15/16"
      assert get_header(resp, "content-length") == "6"
    end

    test "returns 416 without consulting the backend", %{opts: opts} do
      resp = get_range("/streamed.txt", "bytes=16-", opts)

      assert resp.status == 416
      assert get_header(resp, "content-range") == "bytes */16"
    end
  end

  describe "HEAD" do
    test "returns headers without body", %{opts: opts} do
      conn(:put, "/test.txt", "hello")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      resp = conn(:head, "/test.txt") |> call(opts)

      assert resp.status == 200
      assert resp.resp_body == ""
      assert get_header(resp, "content-type") == "text/plain"
    end
  end

  # --- MKCOL ---

  describe "MKCOL" do
    test "creates a collection", %{opts: opts} do
      resp = conn(:mkcol, "/newdir") |> call(opts)

      assert resp.status == 201
    end

    test "returns 409 when parent does not exist", %{opts: opts} do
      resp = conn(:mkcol, "/a/b") |> call(opts)

      assert resp.status == 409
    end

    test "returns 405 when resource already exists", %{opts: opts} do
      conn(:mkcol, "/dir") |> call(opts)
      resp = conn(:mkcol, "/dir") |> call(opts)

      assert resp.status == 405
    end
  end

  # --- DELETE ---

  describe "DELETE" do
    test "deletes a file", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)
      resp = conn(:delete, "/test.txt") |> call(opts)

      assert resp.status == 204

      get_resp = conn(:get, "/test.txt") |> call(opts)
      assert get_resp.status == 404
    end

    test "deletes a collection recursively", %{opts: opts} do
      conn(:mkcol, "/dir") |> call(opts)
      conn(:put, "/dir/file.txt", "data") |> call(opts)
      resp = conn(:delete, "/dir") |> call(opts)

      assert resp.status == 204

      assert (conn(:get, "/dir/file.txt") |> call(opts)).status == 404
    end

    test "returns 404 for nonexistent resource", %{opts: opts} do
      resp = conn(:delete, "/nope") |> call(opts)

      assert resp.status == 404
    end
  end

  # --- COPY ---

  describe "COPY" do
    test "copies a file", %{opts: opts} do
      conn(:put, "/src.txt", "data") |> call(opts)

      resp =
        conn(:copy, "/src.txt")
        |> put_req_header("destination", "/dest.txt")
        |> call(opts)

      assert resp.status == 201

      get_resp = conn(:get, "/dest.txt") |> call(opts)
      assert get_resp.status == 200
      assert get_resp.resp_body == "data"

      # Source still exists
      assert (conn(:get, "/src.txt") |> call(opts)).status == 200
    end

    test "copies with overwrite", %{opts: opts} do
      conn(:put, "/src.txt", "new") |> call(opts)
      conn(:put, "/dest.txt", "old") |> call(opts)

      resp =
        conn(:copy, "/src.txt")
        |> put_req_header("destination", "/dest.txt")
        |> put_req_header("overwrite", "T")
        |> call(opts)

      assert resp.status == 204
    end

    test "returns 412 with overwrite=F and existing destination", %{opts: opts} do
      conn(:put, "/src.txt", "data") |> call(opts)
      conn(:put, "/dest.txt", "existing") |> call(opts)

      resp =
        conn(:copy, "/src.txt")
        |> put_req_header("destination", "/dest.txt")
        |> put_req_header("overwrite", "F")
        |> call(opts)

      assert resp.status == 412
    end

    test "returns 400 without destination header", %{opts: opts} do
      conn(:put, "/src.txt", "data") |> call(opts)
      resp = conn(:copy, "/src.txt") |> call(opts)

      assert resp.status == 400
    end

    test "copies a collection recursively", %{opts: opts} do
      conn(:mkcol, "/srcdir") |> call(opts)
      conn(:put, "/srcdir/file.txt", "data") |> call(opts)

      resp =
        conn(:copy, "/srcdir")
        |> put_req_header("destination", "/destdir")
        |> call(opts)

      assert resp.status == 201

      get_resp = conn(:get, "/destdir/file.txt") |> call(opts)
      assert get_resp.status == 200
      assert get_resp.resp_body == "data"
    end
  end

  # --- MOVE ---

  describe "MOVE" do
    test "moves a file", %{opts: opts} do
      conn(:put, "/src.txt", "data") |> call(opts)

      resp =
        conn(:move, "/src.txt")
        |> put_req_header("destination", "/dest.txt")
        |> call(opts)

      assert resp.status == 201

      assert (conn(:get, "/dest.txt") |> call(opts)).status == 200
      assert (conn(:get, "/src.txt") |> call(opts)).status == 404
    end

    test "prevents move to descendant of self", %{opts: opts} do
      conn(:mkcol, "/parent") |> call(opts)

      resp =
        conn(:move, "/parent")
        |> put_req_header("destination", "/parent/child")
        |> call(opts)

      assert resp.status == 403
    end
  end

  # --- PROPFIND ---

  describe "PROPFIND" do
    test "returns properties for a file (allprop, empty body)", %{opts: opts} do
      conn(:put, "/test.txt", "hello")
      |> put_req_header("content-type", "text/plain")
      |> call(opts)

      resp =
        conn(:propfind, "/test.txt")
        |> put_req_header("depth", "0")
        |> call(opts)

      assert resp.status == 207
      assert get_header(resp, "content-type") =~ "application/xml"

      body = resp.resp_body
      assert body =~ "multistatus"
      assert body =~ "getcontentlength"
      assert body =~ "resourcetype"
      assert body =~ "getetag"
    end

    test "returns properties for a collection with depth 1", %{opts: opts} do
      conn(:mkcol, "/dir") |> call(opts)
      conn(:put, "/dir/a.txt", "aaa") |> call(opts)
      conn(:put, "/dir/b.txt", "bbb") |> call(opts)

      resp =
        conn(:propfind, "/dir")
        |> put_req_header("depth", "1")
        |> call(opts)

      assert resp.status == 207
      body = resp.resp_body
      # Should have responses for /dir, /dir/a.txt, /dir/b.txt
      assert length(String.split(body, "<D:response>")) - 1 == 3
    end

    test "handles propname request", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      propfind_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:">
        <D:propname/>
      </D:propfind>
      """

      resp =
        conn(:propfind, "/test.txt", propfind_body)
        |> put_req_header("depth", "0")
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "resourcetype"
    end

    test "handles specific property request", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      propfind_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propfind xmlns:D="DAV:">
        <D:prop>
          <D:getcontentlength/>
          <D:getetag/>
          <D:nonexistent/>
        </D:prop>
      </D:propfind>
      """

      resp =
        conn(:propfind, "/test.txt", propfind_body)
        |> put_req_header("depth", "0")
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 207
      body = resp.resp_body
      assert body =~ "getcontentlength"
      assert body =~ "200 OK"
      assert body =~ "404 Not Found"
    end

    test "returns 403 for depth infinity when not allowed", %{opts: opts} do
      resp =
        conn(:propfind, "/")
        |> put_req_header("depth", "infinity")
        |> call(opts)

      assert resp.status == 403
    end

    test "handles namespace prefix variations", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      propfind_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <propfind xmlns="DAV:">
        <prop>
          <getcontentlength/>
        </prop>
      </propfind>
      """

      resp =
        conn(:propfind, "/test.txt", propfind_body)
        |> put_req_header("depth", "0")
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "getcontentlength"
    end

    test "returns collection resourcetype for directories", %{opts: opts} do
      conn(:mkcol, "/dir") |> call(opts)

      resp =
        conn(:propfind, "/dir")
        |> put_req_header("depth", "0")
        |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "collection"
    end
  end

  # --- PROPPATCH ---

  describe "PROPPATCH" do
    test "sets properties", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      proppatch_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propertyupdate xmlns:D="DAV:">
        <D:set>
          <D:prop>
            <D:displayname>My File</D:displayname>
          </D:prop>
        </D:set>
      </D:propertyupdate>
      """

      resp =
        conn(:proppatch, "/test.txt", proppatch_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 207
      assert resp.resp_body =~ "200 OK"
    end

    test "returns 404 for nonexistent resource", %{opts: opts} do
      proppatch_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:propertyupdate xmlns:D="DAV:">
        <D:set>
          <D:prop>
            <D:displayname>Name</D:displayname>
          </D:prop>
        </D:set>
      </D:propertyupdate>
      """

      resp =
        conn(:proppatch, "/nonexistent", proppatch_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 404
    end
  end

  # --- LOCK / UNLOCK ---

  describe "LOCK" do
    test "creates an exclusive lock", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      lock_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
        <D:owner><D:href>user@example.com</D:href></D:owner>
      </D:lockinfo>
      """

      resp =
        conn(:lock, "/test.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> put_req_header("timeout", "Second-600")
        |> call(opts)

      assert resp.status == 200
      assert get_header(resp, "lock-token") =~ "opaquelocktoken:"
      assert resp.resp_body =~ "lockdiscovery"
      assert resp.resp_body =~ "exclusive"
    end

    test "returns 423 when lock conflicts", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      lock_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
      </D:lockinfo>
      """

      # First lock succeeds
      conn(:lock, "/test.txt", lock_body)
      |> put_req_header("content-type", "application/xml")
      |> call(opts)

      # Second lock conflicts
      resp =
        conn(:lock, "/test.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 423
    end

    test "creates lock on nonexistent resource (lock-null)", %{opts: opts} do
      lock_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
      </D:lockinfo>
      """

      resp =
        conn(:lock, "/new-file.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      assert resp.status == 201
    end

    test "PUT requires lock token on locked resource", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      lock_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
      </D:lockinfo>
      """

      lock_resp =
        conn(:lock, "/test.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      token =
        get_header(lock_resp, "lock-token")
        |> String.trim_leading("<")
        |> String.trim_trailing(">")

      # PUT without token should fail
      resp = conn(:put, "/test.txt", "new data") |> call(opts)
      assert resp.status == 423

      # PUT with token should succeed
      resp =
        conn(:put, "/test.txt", "new data")
        |> put_req_header("if", "(<#{token}>)")
        |> call(opts)

      assert resp.status == 204
    end
  end

  describe "UNLOCK" do
    test "releases a lock", %{opts: opts} do
      conn(:put, "/test.txt", "data") |> call(opts)

      lock_body = """
      <?xml version="1.0" encoding="utf-8"?>
      <D:lockinfo xmlns:D="DAV:">
        <D:lockscope><D:exclusive/></D:lockscope>
        <D:locktype><D:write/></D:locktype>
      </D:lockinfo>
      """

      lock_resp =
        conn(:lock, "/test.txt", lock_body)
        |> put_req_header("content-type", "application/xml")
        |> call(opts)

      lock_token = get_header(lock_resp, "lock-token")

      resp =
        conn(:unlock, "/test.txt")
        |> put_req_header("lock-token", lock_token)
        |> call(opts)

      assert resp.status == 204

      # Now PUT should work without token
      resp = conn(:put, "/test.txt", "new data") |> call(opts)
      assert resp.status == 204
    end

    test "returns 400 without lock-token header", %{opts: opts} do
      resp = conn(:unlock, "/test.txt") |> call(opts)
      assert resp.status == 400
    end

    test "returns 409 for unknown token", %{opts: opts} do
      resp =
        conn(:unlock, "/test.txt")
        |> put_req_header("lock-token", "<opaquelocktoken:unknown>")
        |> call(opts)

      assert resp.status == 409
    end
  end

  # --- Unsupported method ---

  describe "unsupported methods" do
    test "returns 405 for POST", %{opts: opts} do
      resp = conn(:post, "/test", "body") |> call(opts)
      assert resp.status == 405
    end
  end

  # --- Helpers ---

  defp get_header(conn, name) do
    case Plug.Conn.get_resp_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp put_req_header(conn, key, value), do: Plug.Conn.put_req_header(conn, key, value)
end
