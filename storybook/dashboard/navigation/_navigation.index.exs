defmodule Storybook.Dashboard.Navigation do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "compass", :thin}
  def folder_name, do: "Navigation"
end
