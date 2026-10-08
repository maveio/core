defmodule MaveCore.Embeds.EmbedSettings do
  @moduledoc false
  use MaveCore.Schema
  import Ecto.Changeset

  alias MaveCore.Spaces.Space

  @dashboard_fields [
    :width,
    :height,
    :aspect_ratio_enabled,
    :aspect_ratio,
    :color,
    :opacity,
    :controls_enabled,
    :controls,
    :autoplay_enabled,
    :autoplay,
    :loop_enabled,
    :poster,
    :poster_time_seconds,
    :poster_time_hour,
    :poster_time_minute,
    :poster_time_second,
    :external_poster
  ]

  def dashboard_fields, do: @dashboard_fields

  schema "embed_settings" do
    field :width, :string, default: "100%"
    field :height, :string, default: "100%"
    field :aspect_ratio_enabled, :boolean, default: true
    field :aspect_ratio, Ecto.Enum, values: [:r16_9, :r1_1, :r4_3, :auto], default: :r16_9
    field :color, :string
    field :opacity, :integer, default: 100
    field :controls_enabled, :boolean, default: true
    field :controls, Ecto.Enum, values: [:full, :big, :none], default: :full
    field :autoplay_enabled, :boolean, default: false
    field :autoplay, Ecto.Enum, values: [:always, :on_show], default: :on_show
    field :loop_enabled, :boolean, default: false
    field :poster, Ecto.Enum, values: [:upload, :timecode], default: :upload
    field :poster_time_seconds, :float
    field :poster_time_hour, :integer, virtual: true
    field :poster_time_minute, :integer, virtual: true
    field :poster_time_second, :float, virtual: true
    field :external_poster, :string

    belongs_to :space, Space

    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:space_id | @dashboard_fields])
    |> normalize_poster_time()
    |> validate_number(:opacity, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:space_id)
  end

  defp normalize_poster_time(changeset) do
    if Enum.any?(
         [:poster_time_hour, :poster_time_minute, :poster_time_second],
         &changed?(changeset, &1)
       ) do
      hour = number_or_zero(get_field(changeset, :poster_time_hour))
      minute = number_or_zero(get_field(changeset, :poster_time_minute))
      second = float_or_zero(get_field(changeset, :poster_time_second))

      put_change(changeset, :poster_time_seconds, max(hour * 3600 + minute * 60 + second, 0.0))
    else
      changeset
    end
  end

  defp number_or_zero(value) when is_integer(value), do: value
  defp number_or_zero(value) when is_float(value), do: trunc(value)
  defp number_or_zero(_), do: 0

  defp float_or_zero(value) when is_float(value), do: value
  defp float_or_zero(value) when is_integer(value), do: value * 1.0
  defp float_or_zero(_), do: 0.0
end
