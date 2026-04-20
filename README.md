# Davy

A Plug-based library for building WebDAV-compatible file servers in Elixir.

Davy handles the WebDAV HTTP protocol (RFC 4918) — PROPFIND/PROPPATCH XML
processing, multistatus responses, COPY/MOVE semantics, locking, and client
compatibility — and delegates actual storage operations to a user-provided
backend module implementing the `Davy.Backend` behaviour.

## Installation

Add `davy` to your dependencies:

```elixir
def deps do
  [{:davy, "~> 0.2.0"}]
end
```

## Quick start

1. Implement the `Davy.Backend` behaviour
2. Mount `Davy.Plug` in your router:

```elixir
forward "/dav", Davy.Plug, backend: MyApp.DavBackend
```

## Features

- **Class 1 and 2 WebDAV compliance** — all required methods including locking
- **Pluggable backend** — implement a behaviour to connect any storage system
- **Client compatibility** — handles macOS Finder, Windows Explorer, and davfs2 quirks
- **Namespace-aware XML** — correct handling of DAV: namespace with arbitrary prefixes
- **Pluggable lock store** — built-in ETS store or provide your own for distributed locking

## Supported methods

| Method | Description |
|--------|-------------|
| OPTIONS | Capability discovery |
| GET / HEAD | Read file content |
| PUT | Create or replace files |
| DELETE | Remove resources (recursive for collections) |
| MKCOL | Create collections (directories) |
| COPY | Copy resources |
| MOVE | Move/rename resources |
| PROPFIND | Retrieve resource properties |
| PROPPATCH | Modify resource properties |
| LOCK | Acquire write locks |
| UNLOCK | Release write locks |

## References

- [RFC 4918 — WebDAV](https://www.rfc-editor.org/rfc/rfc4918)

## Licence

[Apache-2.0](LICENSE)
