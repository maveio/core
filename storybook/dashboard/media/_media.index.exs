defmodule Storybook.Dashboard.Media do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "photo-film", :thin}
  def folder_name, do: "Media"
end
