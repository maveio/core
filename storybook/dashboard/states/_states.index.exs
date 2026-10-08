defmodule Storybook.Dashboard.States do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "spinner", :thin}
  def folder_name, do: "States"
end
