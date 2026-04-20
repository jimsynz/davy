defmodule Davy do
  @moduledoc """
  A Plug-based library for building WebDAV-compatible file servers in Elixir.

  Davy handles the WebDAV HTTP protocol (RFC 4918) — PROPFIND/PROPPATCH XML
  processing, multistatus responses, COPY/MOVE semantics, locking, and client
  compatibility — and delegates actual storage operations to a user-provided
  backend module implementing the `Davy.Backend` behaviour.

  ## Quick start

  1. Implement the `Davy.Backend` behaviour
  2. Mount `Davy.Plug` in your router

  ```elixir
  forward "/dav", Davy.Plug, backend: MyApp.DavBackend
  ```
  """
end
