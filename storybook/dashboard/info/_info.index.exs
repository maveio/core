defmodule Storybook.Dashboard.Info do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "circle-info", :thin}
  def folder_name, do: "Info"
end
