defmodule MaveCore.Mailer.ScalewayAdapterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Swoosh.Email

  alias MaveCore.Mailer

  setup {Req.Test, :verify_on_exit!}

  setup do
    previous_req_options = Req.default_options()

    on_exit(fn ->
      Req.default_options(previous_req_options)
    end)

    :ok
  end

  test "delivers email through Scaleway Transactional Email API" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/transactional-email/v1alpha1/regions/fr-par/emails"
      assert get_req_header(conn, "x-auth-token") == ["secret-token"]

      payload = conn |> Req.Test.raw_body() |> Jason.decode!()

      assert payload["project_id"] == "project-id"
      assert payload["from"] == %{"email" => "noreply@mave.io", "name" => "mave"}
      assert payload["to"] == [%{"email" => "person@example.com", "name" => "Person"}]
      assert payload["cc"] == [%{"email" => "cc@example.com"}]
      assert payload["bcc"] == [%{"email" => "bcc@example.com"}]
      assert payload["subject"] == "Welcome to mave"
      assert payload["text"] == "Hello"
      assert payload["html"] == "<p>Hello</p>"

      assert %{
               "name" => "invoice.pdf",
               "type" => "application/pdf",
               "content" => "cGRm"
             } in payload["attachments"]

      assert %{"key" => "Reply-To", "value" => "Support <support@mave.io>"} in payload[
               "additional_headers"
             ]

      assert %{"key" => "X-Mave-Test", "value" => "yes"} in payload["additional_headers"]

      Req.Test.json(conn, %{"id" => "email-id"})
    end)

    email =
      new()
      |> from({"mave", "noreply@mave.io"})
      |> to({"Person", "person@example.com"})
      |> cc("cc@example.com")
      |> bcc("bcc@example.com")
      |> reply_to({"Support", "support@mave.io"})
      |> header("X-Mave-Test", "yes")
      |> subject("Welcome to mave")
      |> text_body("Hello")
      |> html_body("<p>Hello</p>")
      |> attachment(
        Swoosh.Attachment.new({:data, "pdf"},
          filename: "invoice.pdf",
          content_type: "application/pdf"
        )
      )

    assert {:ok, %{id: "email-id"}} =
             Mailer.deliver(email,
               adapter: MaveCore.Mailer.ScalewayAdapter,
               project_id: "project-id",
               secret_key: "secret-token"
             )
  end

  test "returns provider errors" do
    Req.default_options(plug: {Req.Test, __MODULE__})

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> put_status(401)
      |> Req.Test.json(%{"message" => "unauthorized"})
    end)

    email =
      new()
      |> from("noreply@mave.io")
      |> to("person@example.com")
      |> subject("Welcome to mave")
      |> text_body("Hello")

    assert {:error, {401, %{"message" => "unauthorized"}}} =
             Mailer.deliver(email,
               adapter: MaveCore.Mailer.ScalewayAdapter,
               project_id: "project-id",
               secret_key: "bad-token"
             )
  end
end
