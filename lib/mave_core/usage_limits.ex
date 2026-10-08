defmodule MaveCore.UsageLimits do
  @moduledoc """
  Optional runtime usage-limit checks for host applications.
  """

  alias MaveCore.Media.RemoteSource
  alias MaveCore.Spaces.Space

  @callback can_create_video_embed?(Space.t()) :: :ok | {:error, term()}
  @callback can_add_space_member?(Space.t(), String.t() | atom()) :: :ok | {:error, term()}
  @callback can_view_space_data?(Space.t()) :: :ok | {:error, term()}
  @callback can_upload_file?(Space.t(), non_neg_integer() | nil) :: :ok | {:error, term()}
  @callback restriction_copy(atom(), term()) :: %{optional(atom()) => String.t()}

  @optional_callbacks can_view_space_data?: 1, can_upload_file?: 2, restriction_copy: 2

  def can_create_video_embed?(%Space{} = space) do
    dispatch(:can_create_video_embed?, [space])
  end

  def can_add_space_member?(%Space{} = space, role) do
    dispatch(:can_add_space_member?, [space, role])
  end

  def can_view_space_data?(%Space{} = space) do
    dispatch(:can_view_space_data?, [space])
  end

  def can_upload_file?(%Space{} = space, size) when is_integer(size) or is_nil(size) do
    with :ok <- enforce_core_media_input_limit(size) do
      dispatch(:can_upload_file?, [space, size])
    end
  end

  def restriction_copy(operation, reason) when is_atom(operation) do
    case dispatch(:restriction_copy, [operation, reason], %{}) do
      copy when is_map(copy) ->
        copy
        |> Map.take([:notice, :help, :error])
        |> Enum.filter(fn {_key, value} -> is_binary(value) and String.trim(value) != "" end)
        |> Map.new()

      _copy ->
        %{}
    end
  end

  defp dispatch(callback, args, default \\ :ok) do
    backend = Application.get_env(:mave_core, :usage_limits_backend)

    if is_atom(backend) and Code.ensure_loaded?(backend) and
         function_exported?(backend, callback, length(args)) do
      apply(backend, callback, args)
    else
      default
    end
  end

  defp enforce_core_media_input_limit(nil), do: {:error, :upload_size_required}

  defp enforce_core_media_input_limit(size) when is_integer(size) and size >= 0 do
    if size <= RemoteSource.max_bytes(),
      do: :ok,
      else: {:error, :upload_file_size_limit_exceeded}
  end
end
