defmodule MaveCore.AudioDescription.Pronunciation do
  @moduledoc "Language-specific spoken forms for URLs without changing the displayed script."
  @letters ~w(aa bee see dee ee ef gee haa ie jee kaa el em en oo pee kuu er es tee uu vee wee iks ij zet)
  @url ~r/\b(?:https?:\/\/)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?:\/[a-z0-9_~%+\-\/.]*)?/i

  def for_speech(text, language) do
    if language |> String.downcase() |> String.split(~r/[-_]/) |> hd() == "nl",
      do: Regex.replace(@url, text, &dutch_url/1),
      else: text
  end

  defp dutch_url(url) do
    url
    |> String.replace(~r/^https?:\/\//i, "")
    |> String.split("/")
    |> Enum.with_index()
    |> Enum.map_join(" schuine streep ", fn
      {host, 0} -> host |> String.split(".") |> Enum.map_join(" punt ", &host_part/1)
      {path, _} -> String.replace(path, ~r/[-_]/, " ")
    end)
  end

  defp host_part(part) do
    part = String.downcase(part)

    if String.length(part) <= 3 and part =~ ~r/^[a-z]+$/,
      do: part |> String.to_charlist() |> Enum.map_join(" ", &Enum.at(@letters, &1 - ?a)),
      else: String.replace(part, "-", " streepje ")
  end
end
