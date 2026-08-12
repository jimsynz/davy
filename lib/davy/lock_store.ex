defmodule Davy.LockStore do
  @moduledoc """
  Behaviour for WebDAV lock storage.

  The default implementation `Davy.LockStore.ETS` provides in-memory locking
  suitable for single-node deployments. Implement this behaviour for
  distributed or persistent locking.

  ## Error channels

  Callbacks report failure two ways, and the distinction matters:

  * **Domain atoms** — `:conflict`, `:not_found`, `:invalid_token` — describe
    what the store found. Davy decides the HTTP status, because the right
    status depends on the request. An unknown token is `412` when refreshing a
    lock and `409` when unlocking; the store cannot know which method it is
    serving, so it must not choose.

  * **`t:Davy.Error.t/0`** — the store itself failed. Use this when the
    backing store is unreachable, times out, or rejects the operation for a
    reason unrelated to lock state. Davy maps the error's code straight to a
    response status, so a distributed store should return
    `%Davy.Error{code: :service_unavailable}` rather than dressing an outage
    up as `:conflict` — a client that receives `423` retries against a lock
    that does not exist instead of backing off.

  Returning a `t:Davy.Error.t/0` from any callback aborts the request with
  that status. There is no fail-open path: a store that cannot answer whether
  a resource is locked will never cause Davy to treat it as unlocked.
  """

  @type path :: [String.t()]
  @type lock_token :: String.t()
  @type lock_scope :: :exclusive | :shared
  @type lock_type :: :write
  @type lock_depth :: 0 | :infinity

  @type lock_info :: %{
          token: lock_token(),
          path: path(),
          scope: lock_scope(),
          type: lock_type(),
          depth: lock_depth(),
          owner: String.t() | nil,
          timeout: pos_integer(),
          expires_at: integer()
        }

  @doc """
  Acquire a lock on the given path with the given depth.

  `depth: 0` locks only the given path.
  `depth: :infinity` locks the path and all descendants — writes to any
  descendant resource must provide the lock token.

  Return `{:error, :conflict}` only when an incompatible lock is already
  held; that becomes a `423 Locked`.
  """
  @callback lock(
              path(),
              lock_scope(),
              lock_type(),
              lock_depth(),
              String.t() | nil,
              pos_integer()
            ) ::
              {:ok, lock_token()} | {:error, :conflict} | {:error, Davy.Error.t()}

  @doc """
  Release a lock by token.
  """
  @callback unlock(lock_token()) :: :ok | {:error, :not_found} | {:error, Davy.Error.t()}

  @doc """
  Refresh an existing lock's timeout. Returns updated lock info.
  """
  @callback refresh(lock_token(), pos_integer()) ::
              {:ok, lock_info()} | {:error, :not_found} | {:error, Davy.Error.t()}

  @doc """
  Return all active locks on the given path.

  Only returns locks whose `path` exactly matches the given path, regardless
  of depth. Use `get_locks_covering/1` to include ancestor locks with
  `depth: :infinity`.
  """
  @callback get_locks(path()) :: {:ok, [lock_info()]} | {:error, Davy.Error.t()}

  @doc """
  Return all active locks covering the given path — the locks on the path
  itself plus any ancestor locks with `depth: :infinity`.

  Used when checking whether a write to a resource is blocked by a parent
  collection lock.
  """
  @callback get_locks_covering(path()) :: {:ok, [lock_info()]} | {:error, Davy.Error.t()}

  @doc """
  Return all active locks on descendants of the given path, regardless of
  depth. The lock on the path itself is NOT included.

  Used when DELETE targets a collection — per RFC 4918 §9.11 the request
  must fail if any descendant is locked by a principal who has not
  supplied the matching token.
  """
  @callback get_descendant_locks(path()) :: {:ok, [lock_info()]} | {:error, Davy.Error.t()}

  @doc """
  Check whether a lock token is valid for the given path.

  Returns `:ok` if the token identifies an active lock whose path either
  matches the given path exactly, or is an ancestor of it with
  `depth: :infinity`.
  """
  @callback check_token(path(), lock_token()) ::
              :ok | {:error, :invalid_token} | {:error, Davy.Error.t()}
end
