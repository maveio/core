defmodule MaveCore.AccountsPublicRegistrationTest do
  use MaveCore.DataCase, async: false

  import Swoosh.TestAssertions

  alias MaveCore.Accounts
  alias MaveCore.Spaces.Space

  setup do
    previous_registration = Application.get_env(:mave_core, :public_registration)
    previous_mailer = Application.get_env(:mave_core, MaveCore.Mailer)

    Application.put_env(:mave_core, :public_registration, enabled: true, max_users: 100)
    Application.put_env(:mave_core, MaveCore.Mailer, adapter: Swoosh.Adapters.Test)

    on_exit(fn ->
      restore_env(:public_registration, previous_registration)
      restore_mailer(previous_mailer)
    end)

    :ok
  end

  test "public registration creates no tenant resources before email confirmation" do
    email = "pending-public-signup@example.com"

    assert {:ok, user} = Accounts.register_public_user(email, &signup_url/1)
    assert user.email == email
    assert is_nil(user.confirmed_at)
    assert is_nil(user.current_space_membership_id)
    assert Repo.aggregate(Space, :count, :id) == 0
    assert_email_sent(subject: "Mave Core signup verification", to: email)
  end

  test "disabled public registration writes nothing" do
    Application.put_env(:mave_core, :public_registration, enabled: false, max_users: 100)
    email = "disabled-public-signup@example.com"

    assert {:error, :public_registration_disabled} =
             Accounts.register_public_user(email, &signup_url/1)

    refute Accounts.get_user_by_email(email)
    assert Repo.aggregate(Space, :count, :id) == 0
    assert_no_email_sent()
  end

  test "failed signup mail rolls back the pending user and token" do
    Application.put_env(:mave_core, MaveCore.Mailer, adapter: false)
    email = "failed-public-signup@example.com"

    assert {:error, :mailer_not_configured} =
             Accounts.register_public_user(email, &signup_url/1)

    refute Accounts.get_user_by_email(email)
    assert Repo.aggregate(Space, :count, :id) == 0
  end

  test "global user limit includes deleted account records" do
    Application.put_env(:mave_core, :public_registration, enabled: true, max_users: 1)
    assert {:ok, owner} = Accounts.create_user("existing-owner@example.com")

    owner
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:error, :public_registration_limit_reached} =
             Accounts.register_public_user("over-limit@example.com", &signup_url/1)

    refute Accounts.get_user_by_email("over-limit@example.com")
  end

  test "new Google users obey policy while existing Google users can still log in" do
    uid = "existing-google-policy-uid"

    assert {:ok, existing_user} =
             Accounts.create_user("existing-google-policy@example.com", %{
               google_uid: uid,
               skip_email_validation: true
             })

    Application.put_env(:mave_core, :public_registration, enabled: false, max_users: 100)

    assert {:error, :public_registration_disabled} =
             Accounts.login_or_register_with_google(%{
               uid: "new-google-policy-uid",
               email: "new-google-policy@example.com",
               email_verified: true
             })

    assert {:ok, logged_in_user} =
             Accounts.login_or_register_with_google(%{
               uid: uid,
               email: existing_user.email,
               email_verified: true
             })

    assert logged_in_user.id == existing_user.id
    refute Accounts.get_user_by_email("new-google-policy@example.com")
  end

  defp signup_url(token), do: "https://manage.example.test/videos?token=#{token}"

  defp restore_env(key, nil), do: Application.delete_env(:mave_core, key)
  defp restore_env(key, value), do: Application.put_env(:mave_core, key, value)

  defp restore_mailer(nil), do: Application.delete_env(:mave_core, MaveCore.Mailer)
  defp restore_mailer(value), do: Application.put_env(:mave_core, MaveCore.Mailer, value)
end
