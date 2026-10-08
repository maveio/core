defmodule MaveCore.Accounts.EmailValidator do
  @moduledoc false

  require Logger

  @type validation_result :: {:ok, true} | {:error, atom()}

  @spec check_email(String.t()) :: validation_result()
  def check_email(email) when is_binary(email) do
    validate_mx_records(email)
  end

  @spec validate_mx_records(String.t()) :: validation_result()
  def validate_mx_records(email) when is_binary(email) do
    checker = email_checker_module()

    checker.valid?(email)
    |> case do
      true -> {:ok, true}
      false -> {:error, :invalid_mx}
      _ -> {:error, :invalid_mx}
    end
  rescue
    error ->
      Logger.warning("MX check failed for email #{email}: #{Exception.message(error)}")
      {:error, :mx_check_failed}
  end

  defp email_checker_module do
    Application.get_env(:mave_core, :email_validation, [])
    |> Keyword.get(:checker, EmailChecker)
  end
end
