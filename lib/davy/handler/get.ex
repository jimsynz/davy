defmodule Davy.Handler.Get do
  @moduledoc false

  import Plug.Conn
  alias Davy.{Error, Handler.Helpers, Telemetry}

  @doc false
  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, opts) do
    path = Helpers.resource_path(conn)

    case Telemetry.span_backend(opts.backend, :resolve, %{path: path}, fn ->
           opts.backend.resolve(opts.auth, path)
         end) do
      {:ok, %{type: :collection}} ->
        send_resp(conn, 405, "Method Not Allowed")

      {:ok, resource} ->
        serve_content(conn, opts, resource)

      {:error, error} ->
        Helpers.send_error(conn, error)
    end
  end

  defp serve_content(conn, opts, resource) do
    case resolve_range(conn, resource) do
      :unsatisfiable -> send_range_not_satisfiable(conn, resource)
      range_opts -> read_and_send(conn, opts, resource, range_opts)
    end
  end

  defp send_range_not_satisfiable(conn, resource) do
    conn
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-range", "bytes */#{resource.content_length}")
    |> Helpers.send_error(%Error{code: :range_not_satisfiable, message: "Range Not Satisfiable"})
  end

  defp read_and_send(conn, opts, resource, range_opts) do
    result =
      Telemetry.span_backend(opts.backend, :get_content, %{path: resource.path}, fn ->
        opts.backend.get_content(opts.auth, resource, range_opts)
      end)

    case result do
      {:ok, content} -> send_content(conn, resource, content, range_opts)
      {:error, error} -> Helpers.send_error(conn, error)
    end
  end

  defp send_content(conn, resource, content, range_opts) do
    conn =
      conn
      |> put_content_type(resource)
      |> put_etag(resource)
      |> put_last_modified(resource)
      |> put_resp_header("accept-ranges", "bytes")

    if streamable?(content) do
      send_streamed_content(conn, resource, content, range_opts)
    else
      send_binary_content(conn, resource, content, range_opts)
    end
  end

  defp send_binary_content(conn, resource, content, range_opts) do
    body = if is_list(content), do: IO.iodata_to_binary(content), else: content
    {status, conn} = put_body_headers(conn, resource, range_opts)

    if conn.method == "HEAD" do
      send_resp(conn, status, "")
    else
      send_resp(conn, status, body)
    end
  end

  defp send_streamed_content(conn, resource, stream, range_opts) do
    {status, conn} = put_body_headers(conn, resource, range_opts)

    if conn.method == "HEAD" do
      send_resp(conn, status, "")
    else
      stream_chunks(conn, status, stream)
    end
  end

  defp put_body_headers(conn, resource, %{range: {first, last}}) do
    {206,
     conn
     |> put_resp_header("content-range", "bytes #{first}-#{last}/#{resource.content_length}")
     |> put_resp_header("content-length", Integer.to_string(last - first + 1))}
  end

  defp put_body_headers(conn, resource, _range_opts),
    do: {200, put_content_length(conn, resource)}

  defp stream_chunks(conn, status, stream) do
    conn = send_chunked(conn, status)

    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  defp streamable?(content) when is_binary(content), do: false
  defp streamable?(content) when is_list(content), do: false
  defp streamable?(_content), do: true

  defp put_content_type(conn, %{content_type: ct}) when is_binary(ct),
    do: put_resp_header(conn, "content-type", ct)

  defp put_content_type(conn, _),
    do: put_resp_header(conn, "content-type", "application/octet-stream")

  defp put_etag(conn, %{etag: etag}) when is_binary(etag),
    do: put_resp_header(conn, "etag", etag)

  defp put_etag(conn, _), do: conn

  defp put_last_modified(conn, %{last_modified: %DateTime{} = dt}),
    do: put_resp_header(conn, "last-modified", format_http_date(dt))

  defp put_last_modified(conn, _), do: conn

  defp put_content_length(conn, %{content_length: len}) when is_integer(len),
    do: put_resp_header(conn, "content-length", Integer.to_string(len))

  defp put_content_length(conn, _), do: conn

  defp resolve_range(conn, resource) do
    with ["bytes=" <> spec] <- get_req_header(conn, "range"),
         {:ok, requested} <- parse_byte_range(spec),
         {:ok, first, last} <- resolve_byte_range(requested, resource.content_length) do
      %{range: {first, last}}
    else
      :unsatisfiable -> :unsatisfiable
      _ -> %{}
    end
  end

  defp parse_byte_range(spec) do
    case String.split(spec, "-", parts: 2) do
      [first, ""] -> with {:ok, first} <- parse_position(first), do: {:ok, {:from, first}}
      ["", suffix] -> with {:ok, length} <- parse_position(suffix), do: {:ok, {:suffix, length}}
      [first, last] -> parse_closed_range(first, last)
      _ -> :error
    end
  end

  defp parse_closed_range(first, last) do
    with {:ok, first} <- parse_position(first),
         {:ok, last} <- parse_position(last),
         true <- last >= first do
      {:ok, {:closed, first, last}}
    else
      _ -> :error
    end
  end

  defp parse_position(str) do
    case Integer.parse(str) do
      {position, ""} when position >= 0 -> {:ok, position}
      _ -> :error
    end
  end

  defp resolve_byte_range(_requested, nil), do: :error

  defp resolve_byte_range({:closed, first, last}, total) when first < total,
    do: {:ok, first, min(last, total - 1)}

  defp resolve_byte_range({:from, first}, total) when first < total,
    do: {:ok, first, total - 1}

  defp resolve_byte_range({:suffix, length}, total) when length > 0 and total > 0,
    do: {:ok, max(total - length, 0), total - 1}

  defp resolve_byte_range(_requested, _total), do: :unsatisfiable

  defp format_http_date(datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
