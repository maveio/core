defmodule Storybook.Dashboard.Fields do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "rectangle-list", :thin}
  def folder_name, do: "Fields"
end
