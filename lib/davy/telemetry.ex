defmodule Davy.Telemetry do
  @moduledoc """
  Telemetry events emitted by Davy.

  All events are emitted via `:telemetry.span/3`, so each operation produces
  a `:start` event and either a `:stop` or `:exception` event carrying
  `:duration` and `:monotonic_time` measurements in `:native` time units.

  Attach to individual events with `:telemetry.attach/4` or to a group of
  related events with `:telemetry.attach_many/4`.

  ## Request lifecycle

  Emitted once per WebDAV request, after authentication succeeds and
  before the response is sent.

  `[:davy, :request, :start]`
  `[:davy, :request, :stop]`
  `[:davy, :request, :exception]`

  ### Metadata

  | Key       | Where       | Description                                   |
  | --------- | ----------- | --------------------------------------------- |
  | `:conn`   | start, stop | `Plug.Conn` as it entered/left the dispatcher |
  | `:method` | all         | HTTP method string, e.g. `"PROPFIND"`         |
  | `:path`   | all         | Path segments (URI-decoded) list of strings   |
  | `:status` | stop        | Response status code set on the conn          |

  ## Backend callbacks

  One event namespace per `Davy.Backend` callback. `<operation>` is one of:

  `:authenticate`, `:resolve`, `:get_content`, `:put_content`,
  `:put_content_stream`, `:delete`, `:copy`, `:move`, `:create_collection`,
  `:get_members`, `:get_properties`, `:set_properties`.

  `[:davy, :backend, <operation>, :start]`
  `[:davy, :backend, <operation>, :stop]`
  `[:davy, :backend, <operation>, :exception]`

  ### Metadata

  | Key            | Events              | Description                                 |
  | -------------- | ------------------- | ------------------------------------------- |
  | `:backend`     | all                 | Module implementing `Davy.Backend`          |
  | `:operation`   | all                 | Callback atom                               |
  | `:path`        | most                | Resource path segments                      |
  | `:source_path` | `:copy`, `:move`    | Source path for copy/move                   |
  | `:dest_path`   | `:copy`, `:move`    | Destination path for copy/move              |
  | `:overwrite`   | `:copy`, `:move`    | Whether the destination may be overwritten  |
  | `:properties`  | property operations | List of `{namespace, name}` tuples          |
  | `:conn`        | `:authenticate`     | `Plug.Conn` at authentication time          |
  | `:result`      | stop                | `:ok \\| :error \\| :partial`                 |

  ## Lock store callbacks

  One event namespace per `Davy.LockStore` callback. `<operation>` is one of:

  `:lock`, `:unlock`, `:refresh`, `:get_locks`, `:get_locks_covering`,
  `:get_descendant_locks`, `:check_token`.

  `[:davy, :lock_store, <operation>, :start]`
  `[:davy, :lock_store, <operation>, :stop]`
  `[:davy, :lock_store, <operation>, :exception]`

  ### Metadata

  | Key            | Events                   | Description                     |
  | -------------- | ------------------------ | ------------------------------- |
  | `:lock_store`  | all                      | Module implementing `LockStore` |
  | `:operation`   | all                      | Callback atom                   |
  | `:path`        | path-addressed callbacks | Resource path segments          |
  | `:token`       | token-addressed          | Lock token                      |
  | `:scope`       | `:lock`                  | `:exclusive \\| :shared`         |
  | `:depth`       | `:lock`                  | `0 \\| :infinity`                |
  | `:timeout`     | `:lock`, `:refresh`      | Timeout in seconds              |
  | `:result`      | stop                     | `:ok \\| :error \\| :conflict \\| :not_found` |

  ## Example

      :telemetry.attach_many(
        "davy-logger",
        [
          [:davy, :request, :stop],
          [:davy, :backend, :put_content, :stop],
          [:davy, :lock_store, :lock, :stop]
        ],
        &MyApp.TelemetryLogger.handle/4,
        nil
      )
  """

  @doc false
  @spec span_request(Plug.Conn.t(), (-> Plug.Conn.t())) :: Plug.Conn.t()
  def span_request(conn, fun) do
    start_metadata = %{
      conn: conn,
      method: conn.method,
      path: conn.path_info
    }

    :telemetry.span([:davy, :request], start_metadata, fn ->
      result_conn = fun.()

      stop_metadata =
        %{start_metadata | conn: result_conn} |> Map.put(:status, result_conn.status)

      {result_conn, stop_metadata}
    end)
  end

  @doc false
  @spec span_backend(module(), atom(), map(), (-> result)) :: result when result: term()
  def span_backend(backend, operation, metadata, fun) do
    start_metadata = Map.merge(metadata, %{backend: backend, operation: operation})

    :telemetry.span([:davy, :backend, operation], start_metadata, fn ->
      result = fun.()
      {result, Map.put(start_metadata, :result, summarise_result(result))}
    end)
  end

  @doc false
  @spec span_lock_store(module(), atom(), map(), (-> result)) :: result when result: term()
  def span_lock_store(lock_store, operation, metadata, fun) do
    start_metadata = Map.merge(metadata, %{lock_store: lock_store, operation: operation})

    :telemetry.span([:davy, :lock_store, operation], start_metadata, fn ->
      result = fun.()
      {result, Map.put(start_metadata, :result, summarise_result(result))}
    end)
  end

  defp summarise_result(:ok), do: :ok
  defp summarise_result({:ok, _}), do: :ok
  defp summarise_result({:ok, _, _}), do: :ok
  defp summarise_result({:error, %Davy.Error{code: code}}), do: {:error, code}
  defp summarise_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp summarise_result({:error, _}), do: :error
  defp summarise_result({:partial, _}), do: :partial
  defp summarise_result(list) when is_list(list), do: :ok
  defp summarise_result(_), do: :ok
end
