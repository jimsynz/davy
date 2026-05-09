defmodule Mix.Tasks.Davy.Serve do
  @shortdoc "Starts a Davy WebDAV server for local testing"
  @moduledoc """
  Starts a Bandit HTTP server routing to `Davy.Plug` and blocks until the
  process is terminated.

  Useful for smoke testing a backend implementation against a real WebDAV
  client (macOS Finder, Windows Explorer, `cadaver`, `davfs2`, etc.) without
  wiring the plug into an application.

  ## Usage

      mix davy.serve [options]

  With no options, serves `Davy.Backend.InMemory` on `127.0.0.1:4918`.

  ## Options

    * `--backend Module` — module implementing `Davy.Backend`
      (default: `Davy.Backend.InMemory`). The task calls `start/0` on the
      backend if such a function exists, so `Davy.Backend.InMemory` is
      initialised automatically; other backends may need to be started
      externally before the task runs.

    * `--port N` — TCP port to listen on (default: `4918`).

    * `--ip ADDRESS` — IP address to bind to. Accepts `loopback`
      (the default), `any`, or a dotted-quad like `0.0.0.0`.

  ## Examples

      # Zero-config: in-memory backend on http://127.0.0.1:4918
      mix davy.serve

      # Serve on all interfaces, port 8080
      mix davy.serve --ip any --port 8080

      # Use a custom backend
      mix davy.serve --backend MyApp.DavBackend
  """
  use Mix.Task

  if Code.ensure_loaded?(Bandit) do
    alias Davy.LockStore

    @default_port 4918
    @default_ip :loopback
    @default_backend Davy.Backend.InMemory

    @impl Mix.Task
    def run(argv) do
      {opts, _, _} =
        OptionParser.parse(argv,
          strict: [backend: :string, port: :integer, ip: :string]
        )

      Mix.Task.run("app.start")

      backend = parse_backend(opts[:backend])
      port = opts[:port] || @default_port
      ip = parse_ip(opts[:ip])

      maybe_start_backend(backend)
      LockStore.ETS.reset()

      {:ok, _pid} =
        Bandit.start_link(
          plug: {Davy.Plug, [backend: backend]},
          port: port,
          ip: ip,
          startup_log: false
        )

      Mix.shell().info("""
      Davy WebDAV server listening on #{display_url(ip, port)}
        backend:    #{inspect(backend)}
        lock store: #{inspect(LockStore.ETS)}

      Press Ctrl+C twice to stop.
      """)

      Process.sleep(:infinity)
    end

    defp parse_backend(nil), do: @default_backend

    defp parse_backend(name) do
      module = Module.concat([name])
      Code.ensure_loaded!(module)

      unless function_exported?(module, :authenticate, 1) do
        Mix.raise(
          "backend #{inspect(module)} does not implement Davy.Backend (no authenticate/1)"
        )
      end

      module
    end

    defp parse_ip(nil), do: @default_ip
    defp parse_ip("loopback"), do: :loopback
    defp parse_ip("any"), do: :any

    defp parse_ip(address) do
      case :inet.parse_address(to_charlist(address)) do
        {:ok, tuple} -> tuple
        {:error, _} -> Mix.raise("invalid --ip #{inspect(address)}")
      end
    end

    defp maybe_start_backend(backend) do
      Code.ensure_loaded!(backend)
      if function_exported?(backend, :start, 0), do: backend.start()
    end

    defp display_url(:loopback, port), do: "http://127.0.0.1:#{port}"
    defp display_url(:any, port), do: "http://0.0.0.0:#{port}"

    defp display_url(tuple, port) when is_tuple(tuple),
      do: "http://#{:inet.ntoa(tuple)}:#{port}"
  else
    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      Bandit is required to run `mix davy.serve` but is not available.

      Davy lists Bandit as a dev/test-only dependency. Add it to your project's
      deps to use this task:

          {:bandit, "~> 1.5"}
      """)
    end
  end
end
