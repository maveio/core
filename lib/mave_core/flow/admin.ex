defmodule MaveCore.Flow.Admin do
  @moduledoc """
  Authorization helpers for flow operations surfaces.
  """

  def dashboard_enabled_for?(user) do
    dashboard_enabled_for?(user, nil)
  end

  def dashboard_enabled_for?(%{email: email}, _space) when is_binary(email) do
    flow_admin_email?(email)
  end

  def dashboard_enabled_for?(_user, _space), do: false

  defp flow_admin_email?(email) do
    normalized = normalize(email)

    normalized in configured_admin_emails() or
      email_domain(normalized) in configured_admin_domains()
  end

  defp configured_admin_emails do
    :mave_core
    |> Application.get_env(:flow_admin, [])
    |> Keyword.get(:emails, [])
    |> normalize_list()
  end

  defp configured_admin_domains do
    :mave_core
    |> Application.get_env(:flow_admin, [])
    |> Keyword.get(:email_domains, [])
    |> normalize_list()
  end

  defp normalize_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(_values), do: []

  defp normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp normalize(_value), do: ""

  defp email_domain(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] -> domain
      _ -> ""
    end
  end
end
