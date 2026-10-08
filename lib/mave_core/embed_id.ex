defmodule MaveCore.EmbedId do
  @moduledoc false

  @space_hash_length 5
  @embed_hash_length 10
  @embed_id_length @space_hash_length + @embed_hash_length

  @type split :: %{space_hash: String.t(), embed_hash: String.t()}

  @spec split(String.t()) :: {:ok, split()} | :error
  def split(embed_id) when is_binary(embed_id) do
    if String.length(embed_id) == @embed_id_length do
      {:ok,
       %{
         space_hash: String.slice(embed_id, 0, @space_hash_length),
         embed_hash: String.slice(embed_id, @space_hash_length, @embed_hash_length)
       }}
    else
      :error
    end
  end
end
