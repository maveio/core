defmodule MaveCore.Chapters.Stopwords do
  @moduledoc false
  # Function words carry no topic. Lists are deliberately short: the local
  # chapter writer also gives less weight to words that are used in many lines.

  @words %{
    "en" => ~w(
      a about above after again all also am an and any are as at be because been
      before being below between both but by can could did do does doing done down
      during each even few for from further get gets getting go goes going gonna got
      had has have having he her here hers him his how i if in into is it its just
      kind know let like little lot make many may maybe me might more most much must
      my need no not now of off ok okay on once one only or other our out over own
      really right said same say see she should so some something sort still such
      take than that the their them then there these they thing things think this
      those through to too two under until up us use used using very want was way we
      well were what when where which while who why will with would yeah yes you your
      actually basically thats dont youre were ive lets cant doesnt welcome finally
      first second third next start begin thanks today short long time every everything
    ),
    "nl" => ~w(
      aan al alle alleen als altijd andere ben bent bij dan dat de der deze die dit
      doen door dus een eens en er even ga gaan gaat geen gewoon had heb hebben hebt
      heeft heel hem het hier hij hoe hun iets ik in is ja je jij jou jouw juist kan
      kunnen kunt maar mag me meer met mij mijn moet moeten na naar natuurlijk nee
      net niet nog nou nu of om omdat onder ons onze ook op over staat te tegen toch
      toen tot uit uw van veel voor waar want waren was wat we wel werd wie wij wil
      willen word worden wordt zal ze zeg zelf zich zie zien zij zijn zo zoals zou
      zullen echt eigenlijk gaan komt komen kijken beetje namelijk daar daarna dit
    ),
    "de" => ~w(
      aber alle als also am an auch auf aus bei bin bis bist da damit dann das dass
      dem den der des die dies diese dieser doch du durch ein eine einem einen einer
      er es etwas euch für ganz gibt habe haben hat hatte hier ich ihr im in ist ja
      kann kein keine können man mal mehr mein mit muss nach nicht noch nun nur ob
      oder ohne schon sehr sein sich sie sind so über um und uns unser unter viel
      vom von vor war was weil wenn wer werden wie wieder will wir wird wo zu zum zur
    ),
    "fr" => ~w(
      à alors au aussi autre aux avec avoir bien ce cela ces cette comme dans de des
      donc du elle elles en encore est et être fait faire il ils je la le les leur
      lui mais me même mes moi mon ne nos notre nous on ont ou où par pas peu plus
      pour qu que qui sa sans se ses si son sont sur ta te tout tous très tu un une
      va vos votre vous y ça c'est j'ai
    ),
    "es" => ~w(
      a al algo así aquí bien como con cuando de del desde donde dos el ella ellos
      en entre era es esa ese eso esta está están este esto fue ha hace hacer hasta
      hay la las le les lo los más me mi muy no nos o os otro para pero poco por
      porque que qué se ser si sí sin sobre su sus también tan te tiene todo todos
      tu un una uno unos va vamos y ya yo
    )
  }

  @sets Map.new(@words, fn {language, words} -> {language, MapSet.new(words)} end)
  @all @words |> Map.values() |> List.flatten() |> MapSet.new()

  @doc "Stop words for a language code, or all known lists when it is unknown."
  def for_language(language) when is_binary(language) do
    base = language |> String.downcase() |> String.split(~r/[-_]/) |> hd()
    Map.get(@sets, base, @all)
  end

  def for_language(_language), do: @all
end
