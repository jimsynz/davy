defmodule Davy.Error do
  @moduledoc """
  WebDAV error with HTTP status code mapping.

  Backend and lock store callbacks return `{:error, %Davy.Error{}}` to signal
  failures. The `code` atom maps to an HTTP status code via `status_code/1`.

  `code` is a closed union — a code with no `status_code/1` clause is a
  Dialyzer error rather than a silent 500 at runtime.
  """

  @type t :: %__MODULE__{
          code: error_code(),
          message: String.t() | nil
        }

  @type error_code ::
          :bad_gateway
          | :bad_request
          | :conflict
          | :failed_dependency
          | :forbidden
          | :insufficient_storage
          | :internal_error
          | :locked
          | :method_not_allowed
          | :not_found
          | :precondition_failed
          | :request_entity_too_large
          | :service_unavailable
          | :unauthorized
          | :unsupported_media_type

  @enforce_keys [:code]
  defstruct [:code, :message]

  @doc """
  Returns the HTTP status code for the given error code atom.
  """
  @spec status_code(error_code()) :: pos_integer()
  def status_code(:bad_request), do: 400
  def status_code(:unauthorized), do: 401
  def status_code(:forbidden), do: 403
  def status_code(:not_found), do: 404
  def status_code(:method_not_allowed), do: 405
  def status_code(:conflict), do: 409
  def status_code(:precondition_failed), do: 412
  def status_code(:request_entity_too_large), do: 413
  def status_code(:unsupported_media_type), do: 415
  def status_code(:locked), do: 423
  def status_code(:failed_dependency), do: 424
  def status_code(:internal_error), do: 500
  def status_code(:bad_gateway), do: 502
  def status_code(:service_unavailable), do: 503
  def status_code(:insufficient_storage), do: 507
end
