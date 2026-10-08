defmodule Storybook.Dashboard.Settings do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "sliders", :thin}
  def folder_name, do: "Settings"
end
