defmodule MaveCore.CliAuthorizations do
  @moduledoc """
  Short-lived device authorizations used by the Mave CLI browser login flow.

  Only a SHA-256 digest of the high-entropy device code is stored. Approving a
  request records the selected space; the API key is created only when the CLI
  exchanges the device code, preventing abandoned approvals from leaving keys.
  """

  import Ecto.Query

  alias MaveCore.CliAuthorizations.Authorization
  alias MaveCore.Repo
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @expires_in_seconds 600
  @poll_interval_seconds 2
  @insert_attempts 3
  # Anyone can create authorizations, so finished rows must not accumulate. Keep
  # them long enough for the browser page to report an already-used code.
  @retain_after_expiry_seconds 24 * 60 * 60
  @prune_batch_size 10_000

  def expires_in_seconds, do: @expires_in_seconds
  def poll_interval_seconds, do: @poll_interval_seconds

  def create_authorization(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)
    metadata = normalize_client_metadata(Keyword.get(opts, :client_metadata, %{}))
    insert_authorization(now, metadata, @insert_attempts)
  end

  @doc "Deletes authorizations that expired more than a day ago, in bounded batches."
  def prune_expired(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)
    cutoff = DateTime.add(now, -@retain_after_expiry_seconds, :second)

    batch =
      from(a in Authorization,
        where: a.expires_at < ^cutoff,
        order_by: [asc: a.expires_at, asc: a.id],
        select: a.id,
        limit: ^Keyword.get(opts, :batch_size, @prune_batch_size)
      )

    {count, _} = Repo.delete_all(from(a in Authorization, where: a.id in subquery(batch)))
    {:ok, count}
  end

  def get_for_browser(user_code, opts \\ []) when is_binary(user_code) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)

    case Repo.get_by(Authorization, user_code: normalize_user_code(user_code)) do
      nil ->
        {:error, :not_found}

      %Authorization{status: :consumed} = authorization ->
        {:ok, authorization}

      %Authorization{} = authorization ->
        maybe_expire(authorization, now)
    end
  end

  def approve(user_code, %Space{} = space, opts \\ []) when is_binary(user_code) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)

    Repo.transaction(fn ->
      case locked_by_user_code(user_code) do
        nil ->
          {:error, :not_found}

        %Authorization{} = authorization ->
          approve_locked(authorization, space, now)
      end
    end)
    |> transaction_result()
  end

  def deny(user_code, opts \\ []) when is_binary(user_code) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)

    Repo.transaction(fn ->
      case locked_by_user_code(user_code) do
        nil -> {:error, :not_found}
        %Authorization{} = authorization -> deny_locked(authorization, now)
      end
    end)
    |> transaction_result()
  end

  def exchange(device_code, opts \\ [])

  def exchange(device_code, opts) when is_binary(device_code) do
    now = Keyword.get_lazy(opts, :now, &utc_now/0)

    Repo.transaction(fn ->
      device_code
      |> device_code_hash()
      |> locked_by_device_code_hash()
      |> exchange_locked(now)
    end)
    |> transaction_result()
  end

  def exchange(_device_code, _opts), do: {:error, :invalid_grant}

  def normalize_user_code(value) when is_binary(value) do
    normalized =
      value
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/u, "")

    case normalized do
      <<left::binary-size(5), right::binary-size(5)>> -> left <> "-" <> right
      _ -> normalized
    end
  end

  defp normalize_client_metadata(params) when is_map(params) do
    Enum.reduce([{"client", 64}, {"version", 64}, {"device_name", 160}], %{}, fn
      {field, limit}, metadata ->
        case normalize_client_value(Map.get(params, field), limit) do
          nil -> metadata
          value -> Map.put(metadata, field, value)
        end
    end)
  end

  defp normalize_client_metadata(_params), do: %{}

  defp normalize_client_value(value, limit) when is_binary(value) do
    value = value |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "") |> String.trim()
    if value != "" and String.length(value) <= limit, do: value
  end

  defp normalize_client_value(_value, _limit), do: nil

  defp insert_authorization(_now, _metadata, 0), do: {:error, :code_generation_failed}

  defp insert_authorization(now, metadata, attempts_left) do
    device_code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    user_code = generate_user_code()

    attrs = %{
      device_code_hash: device_code_hash(device_code),
      user_code: user_code,
      status: :pending,
      expires_at: DateTime.add(now, @expires_in_seconds, :second),
      client_metadata: metadata
    }

    case %Authorization{} |> Authorization.create_changeset(attrs) |> Repo.insert() do
      {:ok, authorization} ->
        {:ok, %{authorization: authorization, device_code: device_code}}

      {:error, changeset} ->
        if collision?(changeset) do
          insert_authorization(now, metadata, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp approve_locked(%Authorization{status: :pending} = authorization, space, now) do
    if expired?(authorization, now) do
      expire_and_error(authorization)
    else
      authorization
      |> Authorization.approve_changeset(space, now)
      |> Repo.update()
    end
  end

  defp approve_locked(%Authorization{status: :approved} = authorization, _space, now),
    do: maybe_expire(authorization, now)

  defp approve_locked(%Authorization{status: :denied}, _space, _now),
    do: {:error, :access_denied}

  defp approve_locked(%Authorization{status: :expired}, _space, _now),
    do: {:error, :expired_token}

  defp approve_locked(%Authorization{status: :consumed}, _space, _now),
    do: {:error, :already_consumed}

  defp deny_locked(%Authorization{status: :pending} = authorization, now) do
    if expired?(authorization, now) do
      expire_and_error(authorization)
    else
      authorization
      |> Authorization.status_changeset(:denied)
      |> Repo.update()
    end
  end

  defp deny_locked(%Authorization{status: :denied} = authorization, _now),
    do: {:ok, authorization}

  defp deny_locked(%Authorization{status: :expired}, _now), do: {:error, :expired_token}
  defp deny_locked(%Authorization{}, _now), do: {:error, :invalid_state}

  defp exchange_locked(nil, _now), do: {:error, :invalid_grant}

  defp exchange_locked(%Authorization{} = authorization, now) do
    if expired?(authorization, now) do
      expire_and_error(authorization)
    else
      exchange_status(authorization, now)
    end
  end

  defp exchange_status(%Authorization{status: :pending}, _now),
    do: {:error, :authorization_pending}

  defp exchange_status(%Authorization{status: :denied}, _now), do: {:error, :access_denied}
  defp exchange_status(%Authorization{status: :expired}, _now), do: {:error, :expired_token}
  defp exchange_status(%Authorization{status: :consumed}, _now), do: {:error, :invalid_grant}

  defp exchange_status(%Authorization{status: :approved, space_id: space_id} = authorization, now)
       when is_binary(space_id) do
    with %Space{} = space <- Repo.get(Space, space_id),
         {:ok, key} <- Spaces.create_cli_key(space, authorization),
         {:ok, _authorization} <-
           authorization
           |> Authorization.status_changeset(:consumed, %{consumed_at: now})
           |> Repo.update() do
      {:ok,
       %{
         access_token: Spaces.display_api_key(key.key, key.secret),
         token_type: "Bearer",
         space_id: space.id,
         space_hash: space.hash
       }}
    else
      nil -> {:error, :invalid_grant}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exchange_status(%Authorization{}, _now), do: {:error, :invalid_grant}

  defp maybe_expire(%Authorization{} = authorization, now) do
    if expired?(authorization, now),
      do: expire_and_error(authorization),
      else: {:ok, authorization}
  end

  defp expire(%Authorization{status: :expired} = authorization), do: {:ok, authorization}

  defp expire(%Authorization{} = authorization) do
    authorization
    |> Authorization.status_changeset(:expired)
    |> Repo.update()
  end

  defp expire_and_error(authorization) do
    case expire(authorization) do
      {:ok, _authorization} -> {:error, :expired_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp expired?(%Authorization{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp locked_by_user_code(user_code) do
    from(a in Authorization,
      where: a.user_code == ^normalize_user_code(user_code),
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp locked_by_device_code_hash(device_code_hash) do
    from(a in Authorization, where: a.device_code_hash == ^device_code_hash, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp generate_user_code do
    value = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :upper)
    <<left::binary-size(5), right::binary-size(5)>> = value
    left <> "-" <> right
  end

  defp device_code_hash(device_code), do: :crypto.hash(:sha256, device_code)

  defp collision?(changeset) do
    Enum.any?(changeset.errors, fn
      {field, {_message, opts}} when field in [:device_code_hash, :user_code] ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
