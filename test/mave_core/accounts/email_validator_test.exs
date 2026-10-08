defmodule MaveCore.Accounts.EmailValidatorTest do
  use ExUnit.Case, async: false

  alias MaveCore.Accounts.EmailValidator

  defmodule CheckerStub do
    def valid?(email) do
      Process.get({__MODULE__, :result, email}, true)
    end
  end

  setup do
    previous = Application.get_env(:mave_core, :email_validation, [])

    Application.put_env(
      :mave_core,
      :email_validation,
      checker: CheckerStub
    )

    on_exit(fn ->
      Application.put_env(:mave_core, :email_validation, previous)
    end)

    :ok
  end

  test "returns error when MX/domain validation fails" do
    email = "invalid-mx@example.com"
    Process.put({CheckerStub, :result, email}, false)

    assert {:error, :invalid_mx} = EmailValidator.check_email(email)
  end

  test "returns ok when MX/domain validation succeeds" do
    email = "valid-mx@example.com"
    Process.put({CheckerStub, :result, email}, true)

    assert {:ok, true} = EmailValidator.check_email(email)
  end
end
