# Run inside the candidate image/release environment, without starting Mave:
#   mix run --no-start scripts/check_certificate_trust.exs
#   mix run --no-start scripts/check_certificate_trust.exs --network
# External probes are opt-in and require the incident test service to be online.

blocked = ~w(
  86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B
  D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4
  7DD78D5F4F13459A83DFF9ABBBA62EDBAF6F2D102BF257FD712F4D9F2746ED8D
  F2EDAAFF3D9B701FB4D14C9F285F8C0BAD90FC3BCC1FA07D47F4718EDABA34A5
)

read_pem = fn path ->
  for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(File.read!(path)),
      do: der
end

# OTP 29 exposes the DER as the second member of each combined certificate.
system_certs = Enum.map(:public_key.cacerts_get(), &elem(&1, 1))

for {name, certs} <- [
      {"certifi compiled", :certifi.cacerts()},
      {"certifi PEM", read_pem.(:certifi.cacertfile())},
      {"CAStore PEM", read_pem.(CAStore.file_path())},
      {"OS/OTP", system_certs}
    ] do
  fingerprints = Enum.map(certs, &Base.encode16(:crypto.hash(:sha256, &1)))

  if Enum.any?(blocked, &(&1 in fingerprints)) or length(fingerprints) < 100 do
    raise "Unsafe or incomplete trust store: #{name}"
  end

  IO.puts("PASS #{name}: affected roots absent")
end

if "--network" in System.argv() do
  {:ok, _} = Application.ensure_all_started(:req)
  {:ok, _} = Application.ensure_all_started(:hackney)

  clients = [
    {"Req/Finch", fn url -> Req.get(url, retry: false, receive_timeout: 10_000) end},
    {"Hackney",
     fn url ->
       case :hackney.request(:get, url, [], "", connect_timeout: 10_000, with_body: true) do
         {:ok, status, _headers, _body} -> {:ok, status}
         {:error, _reason} = error -> error
       end
     end}
  ]

  for {name, request} <- clients do
    {:ok, _response} = request.("https://example.com/")
    IO.puts("PASS #{name}: ordinary HTTPS works")

    for kind <- ["dv", "ov", "ev"], region <- ["g3b", "g3c"], cross_sign <- ["", "-aaa"] do
      host = "#{kind}-#{region}#{cross_sign}-emudhra.we-have-a-problem.com"

      case request.("https://#{host}/") do
        {:error, reason} ->
          # Timeouts, DNS errors and expired certificates are not proof of distrust.
          unless inspect(reason) =~ "unknown_ca", do: raise("Inconclusive TLS rejection: #{host}")
          IO.puts("PASS #{name}: #{host} rejected (unknown CA)")

        {:ok, _response} ->
          raise "Compromised certificate accepted: #{name}, #{host}"
      end
    end
  end
end
