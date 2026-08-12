defmodule Davy.Test.UnavailableLockStore do
  @moduledoc """
  Lock store that reports every operation as unavailable.

  Stands in for a distributed store whose backing service is unreachable,
  so the handlers can be exercised against the `Davy.Error` channel rather
  than against lock state.
  """

  @behaviour Davy.LockStore

  @error %Davy.Error{code: :service_unavailable, message: "Lock store unreachable"}

  @doc """
  The error every callback returns.
  """
  @spec error() :: Davy.Error.t()
  def error, do: @error

  @impl true
  def lock(_path, _scope, _type, _depth, _owner, _timeout), do: {:error, @error}

  @impl true
  def unlock(_token), do: {:error, @error}

  @impl true
  def refresh(_token, _timeout), do: {:error, @error}

  @impl true
  def get_locks(_path), do: {:error, @error}

  @impl true
  def get_locks_covering(_path), do: {:error, @error}

  @impl true
  def get_descendant_locks(_path), do: {:error, @error}

  @impl true
  def check_token(_path, _token), do: {:error, @error}
end
