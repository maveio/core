defmodule Storybook.Dashboard do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "gauge", :thin}
  def folder_name, do: "Dashboard"
  def folder_open?, do: true
end
