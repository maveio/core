defmodule MaveCore.Mailer.ScalewayAdapter do
  @moduledoc """
  Swoosh adapter for Scaleway Transactional Email.
  """

  use Swoosh.Adapter,
    required_config: [:project_id, :secret_key],
    required_deps: [Req]

  alias Swoosh.{Attachment, Email}

  @base_url "https://api.scaleway.com"

  @impl Swoosh.Adapter
  def deliver(%Email{} = email, config) do
    region = Keyword.get(config, :region, "fr-par")
    base_url = config |> Keyword.get(:base_url, @base_url) |> String.trim_trailing("/")

    response =
      Req.post(
        url: "#{base_url}/transactional-email/v1alpha1/regions/#{region}/emails",
        headers: [{"X-Auth-Token", Keyword.fetch!(config, :secret_key)}],
        json: prepare_body(email, Keyword.fetch!(config, :project_id))
      )

    case response do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, %{id: response_id(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_body(email, project_id) do
    %{
      "project_id" => project_id,
      "from" => prepare_recipient(email.from),
      "to" => Enum.map(email.to, &prepare_recipient/1),
      "subject" => email.subject
    }
    |> maybe_put_present("text", email.text_body)
    |> maybe_put_present("html", email.html_body)
    |> maybe_put_recipients("cc", email.cc)
    |> maybe_put_recipients("bcc", email.bcc)
    |> maybe_put_attachments(email.attachments)
    |> maybe_put_headers(email)
  end

  defp prepare_recipient({name, address}) when is_binary(name) and name != "" do
    %{"email" => address, "name" => name}
  end

  defp prepare_recipient({_name, address}), do: %{"email" => address}

  defp maybe_put_present(body, _key, nil), do: body
  defp maybe_put_present(body, _key, ""), do: body
  defp maybe_put_present(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_recipients(body, _key, []), do: body

  defp maybe_put_recipients(body, key, recipients) do
    Map.put(body, key, Enum.map(recipients, &prepare_recipient/1))
  end

  defp maybe_put_attachments(body, []), do: body

  defp maybe_put_attachments(body, attachments) do
    Map.put(body, "attachments", Enum.map(attachments, &prepare_attachment/1))
  end

  defp prepare_attachment(%Attachment{} = attachment) do
    %{
      "name" => attachment.filename,
      "type" => attachment.content_type,
      "content" => Attachment.get_content(attachment, :base64)
    }
  end

  defp maybe_put_headers(body, email) do
    headers =
      email.headers
      |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
      |> Kernel.++(reply_to_headers(email.reply_to))

    case headers do
      [] -> body
      headers -> Map.put(body, "additional_headers", headers)
    end
  end

  defp reply_to_headers(nil), do: []

  defp reply_to_headers(recipients) when is_list(recipients) do
    Enum.map(recipients, &reply_to_header/1)
  end

  defp reply_to_headers(recipient), do: [reply_to_header(recipient)]

  defp reply_to_header(recipient) do
    %{"key" => "Reply-To", "value" => format_mailbox(recipient)}
  end

  defp format_mailbox({name, address}) when is_binary(name) and name != "" do
    "#{name} <#{address}>"
  end

  defp format_mailbox({_name, address}), do: address

  defp response_id(%{"id" => id}), do: id
  defp response_id(%{id: id}), do: id
  defp response_id(_body), do: nil
end
