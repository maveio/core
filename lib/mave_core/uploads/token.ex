defmodule MaveCore.Uploads.Token do
  @moduledoc """
  Signs API-key HS256 JWTs for `mave-upload`.

  The JWT `sub` follows the public upload contract: a space id, collection
  public id, or video public id.
  """

  alias MaveCore.Spaces
  alias MaveCore.Spaces.Key

  @algorithm "HS256"
  @max_age 86_400
  @admin_upload_claim "mave_admin_upload"
  @admin_upload_signature_claim "mave_admin_upload_sig"

  def sign_api_key(%Key{} = key, sub, opts \\ []) when is_binary(sub) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    max_age = Keyword.get(opts, :max_age, @max_age)
    expires_at = now + max_age

    claims =
      opts
      |> Keyword.get(:claims, %{})
      |> maybe_put_admin_upload_claim(sub, now, expires_at, opts)
      |> Map.merge(%{
        "sub" => sub,
        "iat" => now,
        "exp" => expires_at
      })

    header = %{"alg" => @algorithm, "typ" => "JWT"}

    encoded_header = encode_segment(header)
    encoded_claims = encode_segment(claims)

    signature =
      sign_segment(
        Spaces.display_api_key(key.key, key.secret),
        "#{encoded_header}.#{encoded_claims}"
      )

    Enum.join([encoded_header, encoded_claims, signature], ".")
  end

  def admin_maintenance_bypass?(%{
        "sub" => sub,
        "iat" => issued_at,
        "exp" => expires_at,
        @admin_upload_claim => true,
        @admin_upload_signature_claim => signature
      })
      when is_binary(sub) and is_binary(signature) do
    expected = admin_upload_signature(sub, issued_at, expires_at)

    byte_size(expected) == byte_size(signature) and
      Plug.Crypto.secure_compare(expected, signature)
  end

  def admin_maintenance_bypass?(_claims), do: false

  defp maybe_put_admin_upload_claim(claims, sub, issued_at, expires_at, opts) do
    if Keyword.get(opts, :admin_maintenance_bypass, false) do
      Map.merge(claims, %{
        @admin_upload_claim => true,
        @admin_upload_signature_claim => admin_upload_signature(sub, issued_at, expires_at)
      })
    else
      claims
    end
  end

  defp encode_segment(value) do
    value
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp sign_segment(secret, value) do
    :crypto.mac(:hmac, :sha256, secret, value)
    |> Base.url_encode64(padding: false)
  end

  defp admin_upload_signature(sub, issued_at, expires_at) do
    value = Enum.join(["admin-upload", sub, issued_at, expires_at], ":")

    :mave_core
    |> Application.fetch_env!(:internal_secret)
    |> sign_segment(value)
  end
end
