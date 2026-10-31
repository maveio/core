defmodule MaveCore.DependencySecurityTest do
  use ExUnit.Case, async: true

  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :certificate_body,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  test "partial certificate wildcards cannot consume another DNS label" do
    for {pattern, hostname} <- [
          {~c"*o.example.com", ~c"bar.foo.example.com"},
          {~c"f*o.example.com", ~c"foo.foo.example.com"}
        ] do
      assert {:fail, :unable_to_match_altnames} =
               :ssl_verify_hostname.verify_cert_hostname(dns_certificate(pattern), hostname)
    end
  end

  test "ordinary certificate names and single-label wildcards still match" do
    for {pattern, hostname} <- [
          {~c"www.example.com", ~c"www.example.com"},
          {~c"*.example.com", ~c"www.example.com"},
          {~c"f*o.example.com", ~c"foo.example.com"}
        ] do
      assert {:valid, ^hostname} =
               :ssl_verify_hostname.verify_cert_hostname(dns_certificate(pattern), hostname)
    end
  end

  test "untrusted HTML attribute names cannot introduce additional attributes" do
    for attrs <- [
          [{"x onmouseover", "alert(1)"}],
          [{"x\tonmouseover", "alert(1)"}],
          [{"x onclick=alert(1)", true}],
          [data: [{"x onmouseover", "alert(1)"}]]
        ] do
      assert_raise ArgumentError, fn -> Phoenix.HTML.attributes_escape(attrs) end
    end
  end

  test "legitimate HTML attributes retain nesting and value escaping" do
    html =
      [title: "<>&\"", data: [item_id: "one"], phx_value_id: "two"]
      |> Phoenix.HTML.attributes_escape()
      |> Phoenix.HTML.safe_to_string()

    assert html =~ "title=\"&lt;&gt;&amp;&quot;\""
    assert html =~ "data-item-id=\"one\""
    assert html =~ "phx-value-id=\"two\""
  end

  defp dns_certificate(pattern) do
    certificate(
      tbsCertificate:
        certificate_body(
          extensions: [
            extension(extnID: {2, 5, 29, 17}, critical: false, extnValue: [dNSName: pattern])
          ]
        )
    )
  end
end
