defmodule MaveCore.Accounts.UserToken do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Query

  alias MaveCore.Accounts.User
  @hash_algorithm :sha256
  @rand_size 32

  @login_validity_in_minutes 15
  @invite_validity_in_days 1
  @session_validity_in_days 60

  @user_preloads [
    {:user, [current_space_membership: [:space]]}
  ]

  schema "user_tokens" do
    field(:token, :binary)
    field(:context, :string)
    field(:sent_to, :string)
    field(:attempts, :integer, default: 0)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:invalidated_at, :utc_datetime_usec)

    belongs_to(:user, User)
    belongs_to(:login_token, __MODULE__)

    timestamps()
  end

  def build_session_token(login_token, user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token,
     %__MODULE__{
       login_token_id: login_token.id,
       token: token,
       context: "session",
       user_id: user.id
     }}
  end

  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) do
    query =
      from(token in token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where:
          token.inserted_at > ago(@session_validity_in_days, "day") and
            is_nil(user.deleted_at),
        preload: ^@user_preloads
      )

    {:ok, query}
  end

  def build_email_token(user, context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %__MODULE__{
       token: hashed_token,
       context: context,
       sent_to: user.email,
       user_id: user.id
     }}
  end

  @spec verify_email_token_query(String.t(), String.t()) :: {:ok, Ecto.Query.t()} | :error
  def verify_email_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        validity_in_seconds = validity_in_seconds_for_context(context)

        query =
          from(token in token_and_context_query(hashed_token, context),
            join: user in assoc(token, :user),
            where:
              token.inserted_at > ago(^validity_in_seconds, "second") and
                token.sent_to == user.email and
                is_nil(token.invalidated_at) and
                is_nil(user.deleted_at),
            preload: ^@user_preloads
          )

        {:ok, query}

      :error ->
        :error
    end
  end

  def token_and_context_query(token, context) do
    from(__MODULE__, where: [token: ^token, context: ^context])
  end

  def login_token_query(login_token_id) do
    from(t in __MODULE__, where: t.id == ^login_token_id)
  end

  def session_token_with_login(login_token) do
    from(t in __MODULE__, where: t.login_token_id == ^login_token.id and t.context == "session")
  end

  defp validity_in_seconds_for_context("login"), do: @login_validity_in_minutes * 60
  defp validity_in_seconds_for_context("invite"), do: @invite_validity_in_days * 24 * 60 * 60
  defp validity_in_seconds_for_context(_), do: @login_validity_in_minutes * 60
end
