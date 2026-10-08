defmodule MaveCore.Media.ImageVariant do
  @moduledoc false

  use MaveCore.Schema

  alias MaveCore.Embeds.Embed
  alias MaveCore.Spaces.Space

  schema "image_variants" do
    field :output_path, :string

    belongs_to :space, Space
    belongs_to :embed, Embed

    timestamps(updated_at: false)
  end
end
