defmodule MaveCoreWeb.Live.Dashboard.Settings.EncodingTabTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Flow.Pipelines

  defmodule ManagedPipeline do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_edit_encoding_pipeline?(_space), do: {:error, :managed_pipeline}

    def restriction_copy(:encoding_pipeline, :managed_pipeline),
      do: %{notice: "Your plan uses the standard pipeline."}

    def restriction_copy(_operation, _reason), do: %{}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)

    on_exit(fn ->
      if old_backend,
        do: Application.put_env(:mave_core, :usage_limits_backend, old_backend),
        else: Application.delete_env(:mave_core, :usage_limits_backend)
    end)

    :ok
  end

  test "shows the path from upload to delivery", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings/encoding")

    for stage <- ~w(ingest audio video images subtitles publish deliver) do
      assert has_element?(view, "#pipeline-stage-#{stage}")
    end

    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=enabled]")
    assert has_element?(view, "#pipeline-version", "Standard pipeline")
    refute has_element?(view, "#pipeline-dirty")
    assert has_element?(view, "#pipeline-save[disabled]")
  end

  test "turning off 4K turns off its packaging and saves a version", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings/encoding")

    view |> element("#pipeline-step-video_h264_uhd") |> render_click()
    assert has_element?(view, "#pipeline-inspector-title", "Transcode Video H264 UHD")
    assert has_element?(view, "#pipeline-step-effect", "Package HLS H264 UHD")
    assert has_element?(view, "#pipeline-links")

    view |> element("#pipeline-toggle-video_h264_uhd") |> render_click()

    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=disabled]")
    assert has_element?(view, "#pipeline-step-hls_h264_uhd[data-state=auto_disabled]")
    assert has_element?(view, "#pipeline-step-video_h264_qhd[data-state=enabled]")
    assert has_element?(view, "#pipeline-dirty")
    assert Pipelines.current(space) == nil

    view
    |> form("#pipeline-save-form", %{"pipeline" => %{"note" => "No 4K"}})
    |> render_submit()

    assert %{version: 1, note: "No 4K", overrides: overrides} = Pipelines.current(space)
    assert overrides["disabled_steps"] == ["video_h264_uhd"]
    assert has_element?(view, "#pipeline-version", "Version 1 is live")
    assert has_element?(view, "#pipeline-version-1", "5 steps off")
    refute has_element?(view, "#pipeline-dirty")
  end

  test "required steps have no toggle", %{conn: conn} do
    {conn, _space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings/encoding")

    view |> element("#pipeline-step-manifest") |> render_click()

    assert has_element?(view, "#pipeline-step-state", "Always on")
    refute has_element?(view, "#pipeline-toggle-manifest")

    render_hook_toggle(view, "manifest")
    refute has_element?(view, "#pipeline-dirty")
  end

  test "changes the transcription vocabulary", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings/encoding")

    view |> element("#pipeline-step-transcribe_audio") |> render_click()

    view
    |> form("#pipeline-settings-transcribe_audio", %{
      "setting" => %{"context" => "Mave, Hovercraft"}
    })
    |> render_change()

    assert has_element?(view, "#pipeline-dirty")
    view |> form("#pipeline-save-form") |> render_submit()

    assert Pipelines.current_overrides(space)["settings"] ==
             %{"transcribe_audio" => %{"context" => "Mave, Hovercraft"}}

    assert has_element?(view, "#pipeline-version-1", "1 setting changed")
  end

  test "blocks saving an invalid setting", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, "/settings/encoding")

    view |> element("#pipeline-step-storyboard") |> render_click()

    view
    |> form("#pipeline-settings-storyboard", %{"setting" => %{"count" => "500"}})
    |> render_change()

    assert has_element?(view, "#pipeline-issues", "at most 120")
    assert has_element?(view, "#pipeline-save[disabled]")

    view |> form("#pipeline-save-form") |> render_submit()
    assert Pipelines.current(space) == nil
  end

  test "loads an earlier version into the editor and discards drafts", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    {:ok, _} = Pipelines.save(space, %{"disabled_steps" => ["video_h264_uhd"]})
    {:ok, _} = Pipelines.save(space, %{"disabled_steps" => []})

    {:ok, view, _html} = live(conn, "/settings/encoding")
    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=enabled]")

    view |> element("#pipeline-restore-1") |> render_click()
    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=disabled]")
    assert has_element?(view, "#pipeline-dirty")

    view |> element("#pipeline-discard") |> render_click()
    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=enabled]")
    refute has_element?(view, "#pipeline-dirty")
  end

  test "is read-only when the host manages the pipeline", %{conn: conn} do
    {conn, space} = authenticated_conn(conn)
    Application.put_env(:mave_core, :usage_limits_backend, ManagedPipeline)

    {:ok, view, _html} = live(conn, "/settings/encoding")

    assert has_element?(view, "#pipeline-notice", "Your plan uses the standard pipeline.")
    refute has_element?(view, "#pipeline-save-form")

    view |> element("#pipeline-step-video_h264_uhd") |> render_click()
    render_hook_toggle(view, "video_h264_uhd")

    assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=enabled]")
    assert Pipelines.current(space) == nil
  end

  # Sends the toggle event directly, as a crafted client could.
  defp render_hook_toggle(view, step_id) do
    view
    |> with_target("#encoding-pipeline")
    |> render_click("toggle_step", %{"id" => step_id})
  end

  defp authenticated_conn(conn) do
    email = "encoding-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.create_user(email)
    login_token = Accounts.generate_user_login_token(user)
    {:ok, {logged_in_user, persisted_login_token}} = Accounts.login_user(login_token)
    session_token = Accounts.generate_user_session_token(persisted_login_token, logged_in_user)

    conn =
      conn
      |> with_manage_host()
      |> init_test_session(user_token: session_token)

    {conn, logged_in_user.current_space_membership.space}
  end

  defp with_manage_host(conn) do
    case System.get_env("MAVE_MANAGE_HOST") do
      host when is_binary(host) and host != "" -> %{conn | host: host}
      _ -> conn
    end
  end
end
