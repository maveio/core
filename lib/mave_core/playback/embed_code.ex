defmodule MaveCore.Playback.EmbedCode do
  @moduledoc false

  def add_token(code, type, public_id, tag) when type in [:script, :clip] do
    String.replace(
      code,
      ~s(<#{tag} embed="#{public_id}"),
      ~s(<#{tag} embed="#{public_id}" token="YOUR_PLAYBACK_TOKEN")
    )
  end

  def add_token(code, type, _public_id, tag) when type in [:react, :vue] do
    token_prop = if type == :react, do: "token={playbackToken}", else: ":token=\"playbackToken\""
    code = String.replace(code, "<#{tag} embed=", "<#{tag} #{token_prop} embed=")

    """
    const playbackToken = "YOUR_PLAYBACK_TOKEN";

    """ <> code
  end
end
