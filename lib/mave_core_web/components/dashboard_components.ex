defmodule MaveCoreWeb.DashboardComponents do
  @moduledoc """
  Dashboard UI components for the Mave application.

  These components use the EXACT same Tailwind classes as the legacy ManageUI
  to ensure pixel-perfect consistency. No daisyUI - pure Tailwind only.

  ## Usage

  Import this module in your LiveView or component:

      use MaveCoreWeb, :live_view
      import MaveCoreWeb.DashboardComponents

  ## Component Groups

  This module re-exports components from the following sub-modules:

  - `Buttons` - dash_button, icon_button, icon
  - `Inputs` - dash_input, dash_select, error_tag
  - `Info` - info_box, info_hover
  - `Modals` - modal, dialog
  - `Navigation` - title, menubar, menubar_item, subtitle, section_title, divider, footer
  - `DataTable` - responsive data grids, data_table, data_table_row, data_avatar, toggle
  - `Media` - media_item, media_badge
  - `States` - empty_state, breadcrumb, breadcrumb_bar, usage_bar, progress_bar, led_indicator, rendition_badge
  - `Settings` - settings_panel, settings_header, settings_toggle, settings_option, settings_option_grid, color_picker
  - `Fields` - region_card, copyable_field, copy_button
  - `VideoDetail` - video_embed_panel, video_upload_panel, video_processing_panel, video_metric_card, video_data_section
  """

  # Re-export all components from sub-modules for backwards compatibility
  defdelegate dash_button(assigns), to: MaveCoreWeb.DashboardComponents.Buttons
  defdelegate dropdown_button(assigns), to: MaveCoreWeb.DashboardComponents.Buttons
  defdelegate icon_button(assigns), to: MaveCoreWeb.DashboardComponents.Buttons
  defdelegate icon(assigns), to: MaveCoreWeb.DashboardComponents.Buttons
  defdelegate animated_icon(assigns), to: MaveCoreWeb.DashboardComponents.AnimatedIcon

  defdelegate dash_input(assigns), to: MaveCoreWeb.DashboardComponents.Inputs
  defdelegate dash_select(assigns), to: MaveCoreWeb.DashboardComponents.Inputs
  defdelegate error_tag(assigns), to: MaveCoreWeb.DashboardComponents.Inputs

  defdelegate info_box(assigns), to: MaveCoreWeb.DashboardComponents.Info
  defdelegate info_hover(assigns), to: MaveCoreWeb.DashboardComponents.Info

  defdelegate modal(assigns), to: MaveCoreWeb.DashboardComponents.Modals
  defdelegate dialog(assigns), to: MaveCoreWeb.DashboardComponents.Modals

  defdelegate title(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate menubar(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate menubar_item(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate subtitle(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate section_title(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate divider(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate footer(assigns), to: MaveCoreWeb.DashboardComponents.Navigation

  defdelegate bar(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate logo(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate menu(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate sidebar_usage(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate spacepicker(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate suggest(assigns), to: MaveCoreWeb.DashboardComponents.Navigation
  defdelegate usermenu(assigns), to: MaveCoreWeb.DashboardComponents.Navigation

  defdelegate data_table(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_table_grid(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_table_grid_row(assigns), to: MaveCoreWeb.DashboardComponents.DataTable

  defdelegate data_table_grid_header_cell(assigns),
    to: MaveCoreWeb.DashboardComponents.DataTable

  defdelegate data_table_grid_cell(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_table_header_cell(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_table_row(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_table_cell(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate data_avatar(assigns), to: MaveCoreWeb.DashboardComponents.DataTable
  defdelegate toggle(assigns), to: MaveCoreWeb.DashboardComponents.DataTable

  defdelegate media_item(assigns), to: MaveCoreWeb.DashboardComponents.Media
  defdelegate media_badge(assigns), to: MaveCoreWeb.DashboardComponents.Media

  defdelegate empty_state(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate breadcrumb(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate breadcrumb_bar(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate usage_bar(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate progress_bar(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate led_indicator(assigns), to: MaveCoreWeb.DashboardComponents.States
  defdelegate rendition_badge(assigns), to: MaveCoreWeb.DashboardComponents.States

  # Settings panel components (dark theme)
  defdelegate settings_panel(assigns), to: MaveCoreWeb.DashboardComponents.Settings
  defdelegate settings_header(assigns), to: MaveCoreWeb.DashboardComponents.Settings
  defdelegate settings_toggle(assigns), to: MaveCoreWeb.DashboardComponents.Settings
  defdelegate settings_option(assigns), to: MaveCoreWeb.DashboardComponents.Settings
  defdelegate settings_option_grid(assigns), to: MaveCoreWeb.DashboardComponents.Settings
  defdelegate color_picker(assigns), to: MaveCoreWeb.DashboardComponents.Settings

  # Fields components (copyable fields, region cards, highlight cards)
  defdelegate highlight_card(assigns), to: MaveCoreWeb.DashboardComponents.Fields
  defdelegate region_card(assigns), to: MaveCoreWeb.DashboardComponents.Fields
  defdelegate copyable_field(assigns), to: MaveCoreWeb.DashboardComponents.Fields
  defdelegate secret_field(assigns), to: MaveCoreWeb.DashboardComponents.Fields
  defdelegate copy_button(assigns), to: MaveCoreWeb.DashboardComponents.Fields

  defdelegate video_embed_panel(assigns), to: MaveCoreWeb.DashboardComponents.VideoDetail
  defdelegate video_upload_panel(assigns), to: MaveCoreWeb.DashboardComponents.VideoDetail
  defdelegate video_processing_panel(assigns), to: MaveCoreWeb.DashboardComponents.VideoDetail
  defdelegate video_metric_card(assigns), to: MaveCoreWeb.DashboardComponents.VideoDetail
  defdelegate video_data_section(assigns), to: MaveCoreWeb.DashboardComponents.VideoDetail
end
