defmodule Davy.ConnectionReuseTest do
  @moduledoc """
  Handlers that read a request body must respond on the `conn` returned by
  `Plug.Conn.read_body/2`. Bandit tracks how much of the body it has consumed
  inside that conn's adapter, and drains whatever it believes is outstanding
  once the plug returns. Responding on the pre-read conn makes it drain a
  second time, swallowing the bytes of the next request on the connection.

  These tests send the headers and the body in separate TCP segments so the
  body is not already sitting in Bandit's read buffer — the only case where
  the stale conn is distinguishable from a correctly threaded one.
  """
  use ExUnit.Case, async: false

  alias Davy.Backend.InMemory
  alias Davy.LockStore
  alias Davy.Test.TestServer

  @follow_up "OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n"

  setup do
    InMemory.start()
    LockStore.ETS.reset()
    {:ok, port} = TestServer.start()
    {:ok, port: port}
  end

  test "PROPFIND leaves the connection usable", %{port: port} do
    body = ~s(<?xml version="1.0"?><propfind xmlns="DAV:"><allprop/></propfind>)
    responses = request_then_follow_up(port, "PROPFIND", "/", body)

    assert responses =~ "207 Multi-Status"
    assert_follow_up_answered(responses)
  end

  test "PROPFIND with an unparseable body leaves the connection usable", %{port: port} do
    responses = request_then_follow_up(port, "PROPFIND", "/", "not xml at all")

    assert responses =~ "207 Multi-Status"
    assert_follow_up_answered(responses)
  end

  test "PROPPATCH leaves the connection usable", %{port: port} do
    InMemory.put_content(nil, ["file.txt"], "content", %{content_type: "text/plain"})

    body = """
    <?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:">\
    <D:set><D:prop><X:author xmlns:X="urn:test">Ada</X:author></D:prop></D:set>\
    </D:propertyupdate>
    """

    responses = request_then_follow_up(port, "PROPPATCH", "/file.txt", body)

    assert responses =~ "207 Multi-Status"
    assert_follow_up_answered(responses)
  end

  test "PROPPATCH with an invalid body leaves the connection usable", %{port: port} do
    body = ~s(<?xml version="1.0"?><D:nonsense xmlns:D="DAV:"/>)
    responses = request_then_follow_up(port, "PROPPATCH", "/", body)

    assert responses =~ "400 Bad Request"
    assert_follow_up_answered(responses)
  end

  test "LOCK leaves the connection usable", %{port: port} do
    body = """
    <?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">\
    <D:lockscope><D:exclusive/></D:lockscope>\
    <D:locktype><D:write/></D:locktype>\
    <D:owner>Ada</D:owner>\
    </D:lockinfo>
    """

    responses = request_then_follow_up(port, "LOCK", "/locked.txt", body)

    assert responses =~ "200 OK"
    assert_follow_up_answered(responses)
  end

  test "LOCK with an invalid body leaves the connection usable", %{port: port} do
    body = ~s(<?xml version="1.0"?><D:nonsense xmlns:D="DAV:"/>)
    responses = request_then_follow_up(port, "LOCK", "/locked.txt", body)

    assert responses =~ "400 Bad Request"
    assert_follow_up_answered(responses)
  end

  defp assert_follow_up_answered(responses) do
    assert responses =~ "ms-author-via",
           "the follow-up OPTIONS was never answered, so its bytes were swallowed"
  end

  defp request_then_follow_up(port, method, path, body) do
    headers =
      "#{method} #{path} HTTP/1.1\r\n" <>
        "Host: localhost\r\n" <>
        "Content-Type: application/xml\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n"

    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw], 2_000)

    try do
      :ok = :gen_tcp.send(socket, headers)
      :ok = await_headers_read(socket)
      :ok = :gen_tcp.send(socket, body)
      :ok = :gen_tcp.send(socket, @follow_up)
      read_until_closed(socket, "")
    after
      :gen_tcp.close(socket)
    end
  end

  # The headers have to reach Bandit before the body is sent, otherwise both
  # arrive in one segment and the body is already buffered when the handler
  # reads it.
  defp await_headers_read(socket) do
    case :gen_tcp.recv(socket, 0, 50) do
      {:error, :timeout} -> :ok
      {:ok, _unexpected} -> {:error, :responded_early}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> read_until_closed(socket, acc <> chunk)
      {:error, _closed_or_idle} -> acc
    end
  end
end
