defmodule Storybook.Dashboard.DataTable do
  use PhoenixStorybook.Index

  def folder_icon, do: {:fa, "table", :thin}
  def folder_name, do: "Data Table"
end
