defmodule MaveCore.CertificateTrustTest do
  use ExUnit.Case, async: true

  # The incident includes cross-signs through AAA and the older emSign G3 root.
  @distrusted ~w(
    86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B
    D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4
    7DD78D5F4F13459A83DFF9ABBBA62EDBAF6F2D102BF257FD712F4D9F2746ED8D
    F2EDAAFF3D9B701FB4D14C9F285F8C0BAD90FC3BCC1FA07D47F4718EDABA34A5
  )
  @isrg_root_x1 "96BCEC06264976F37460779ACF28C5A7CFE8A3C0AAE11A8FFCEE05C0BDDF08C6"

  test "certifi's compiled trust matches its PEM and rejects compromised CA paths" do
    embedded = MapSet.new(:certifi.cacerts())
    pem = :certifi.cacertfile() |> read_certificates() |> MapSet.new()

    assert embedded == pem
    assert_safe_trust(embedded)
  end

  test "CAStore rejects the compromised roots while retaining ordinary HTTPS trust" do
    CAStore.file_path() |> read_certificates() |> assert_safe_trust()
  end

  defp read_certificates(path) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(File.read!(path)),
        do: der
  end

  defp assert_safe_trust(certificates) do
    fingerprints =
      MapSet.new(certificates, fn der -> Base.encode16(:crypto.hash(:sha256, der)) end)

    for fingerprint <- @distrusted do
      refute MapSet.member?(fingerprints, fingerprint)
    end

    assert MapSet.member?(fingerprints, @isrg_root_x1)
    assert MapSet.size(fingerprints) > 100
  end
end
