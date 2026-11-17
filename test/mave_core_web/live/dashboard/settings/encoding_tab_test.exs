defmodule MaveCoreWeb.Live.Dashboard.Settings.EncodingTabTest do
  use MaveCoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MaveCore.Accounts
  alias MaveCore.Flow
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

  defmodule PaidSteps do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_encoding_step?(_space, _type), do: {:error, :plan}
    def restriction_copy(:encoding_step, :plan), do: %{notice: "Included from the Pro plan."}
    def restriction_copy(_operation, _reason), do: %{}
  end

  defmodule NoAssistant do
    @behaviour MaveCore.UsageLimits
    def can_create_video_embed?(_space), do: :ok
    def can_add_space_member?(_space, _role), do: :ok
    def can_use_pipeline_assistant?(_space), do: {:error, :plan}

    def restriction_copy(:pipeline_assistant, :plan),
      do: %{notice: "Ask AI for changes from the Pro plan."}

    def restriction_copy(_operation, _reason), do: %{}
  end

  setup do
    old_backend = Application.get_env(:mave_core, :usage_limits_backend)
    old_plugins = Application.get_env(:mave_core, :flow_step_plugins)
    old_storage = Application.get_env(:mave_core, :flow_storage_adapter)
    old_provider = Application.get_env(:mave_core, :pipeline_assistant_provider)
    Application.put_env(:mave_core, :flow_step_plugins, [MaveCore.TestSupport.StepPluginStub])

    Application.put_env(
      :mave_core,
      :pipeline_assistant_provider,
      MaveCore.TestSupport.PipelineAssistantStub
    )

    on_exit(fn ->
      Application.put_env(:mave_core, :flow_step_plugins, old_plugins)
      Application.delete_env(:mave_core, :step_plugin_stub_availability)
      Application.delete_env(:mave_core, :pipeline_assistant_stub)

      if old_provider,
        do: Application.put_env(:mave_core, :pipeline_assistant_provider, old_provider),
        else: Application.delete_env(:mave_core, :pipeline_assistant_provider)

      if old_storage,
        do: Application.put_env(:mave_core, :flow_storage_adapter, old_storage),
        else: Application.delete_env(:mave_core, :flow_storage_adapter)

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

  describe "plugin steps" do
    test "are offered as add-ons that a space can add and configure", %{conn: conn} do
      {conn, space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")

      assert has_element?(view, "#pipeline-stage-checks", "Checks")
      assert has_element?(view, "#pipeline-legend-addon")
      assert has_element?(view, "#pipeline-step-count_source[data-state=disabled]")
      assert has_element?(view, "#pipeline-count-added", "0")

      view |> element("#pipeline-step-count_source") |> render_click()
      assert has_element?(view, "#pipeline-step-plugin", "Add-on")
      assert has_element?(view, "#pipeline-step-state", "Not added")
      assert has_element?(view, "#pipeline-step-inputs", "Source file")
      refute has_element?(view, "#pipeline-step-results")

      view |> element("#pipeline-toggle-count_source") |> render_click()
      assert has_element?(view, "#pipeline-step-count_source[data-state=enabled]")
      assert has_element?(view, "#pipeline-step-state", "Added")
      assert has_element?(view, "#pipeline-step-results", "No results yet")

      view
      |> form("#pipeline-settings-count_source", %{"setting" => %{"limit" => "5"}})
      |> render_change()

      view |> form("#pipeline-save-form") |> render_submit()

      assert %{version: 1, overrides: overrides} = Pipelines.current(space)
      assert overrides["added_steps"] == ["count_source"]
      assert overrides["settings"] == %{"count_source" => %{"limit" => "5"}}
      assert has_element?(view, "#pipeline-version-1", "1 add-on added")
    end

    test "show the results of the latest upload", %{conn: conn} do
      {conn, space} = authenticated_conn(conn)
      {:ok, _} = Pipelines.save(space, %{"added_steps" => ["count_source"]})
      run_upload(space)

      {:ok, view, _html} = live(conn, "/settings/encoding")
      assert has_element?(view, "#pipeline-step-result-count_source", "15 B")

      view |> element("#pipeline-step-count_source") |> render_click()
      assert has_element?(view, "#pipeline-step-results", "Size")
      assert has_element?(view, "#pipeline-step-results", "15 B")
      assert has_element?(view, "#pipeline-step-results", "Within limit")
    end

    test "cannot be added when the installation cannot run them", %{conn: conn} do
      {conn, space} = authenticated_conn(conn)

      Application.put_env(
        :mave_core,
        :step_plugin_stub_availability,
        {:unavailable, "No counter."}
      )

      {:ok, view, _html} = live(conn, "/settings/encoding")

      view |> element("#pipeline-step-count_source") |> render_click()
      assert has_element?(view, "#pipeline-step-effect", "No counter.")
      assert has_element?(view, "#pipeline-toggle-count_source.pointer-events-none")

      render_hook_toggle(view, "count_source")
      assert has_element?(view, "#pipeline-step-count_source[data-state=disabled]")
      refute has_element?(view, "#pipeline-dirty")
      assert Pipelines.current(space) == nil
    end

    test "explain when the host does not include them", %{conn: conn} do
      {conn, _space} = authenticated_conn(conn)
      Application.put_env(:mave_core, :usage_limits_backend, PaidSteps)
      {:ok, view, _html} = live(conn, "/settings/encoding")

      view |> element("#pipeline-step-count_source") |> render_click()
      assert has_element?(view, "#pipeline-step-effect", "Included from the Pro plan.")
      assert has_element?(view, "#pipeline-toggle-count_source.pointer-events-none")
    end
  end

  defp run_upload(space) do
    Application.put_env(
      :mave_core,
      :flow_storage_adapter,
      MaveCore.TestSupport.FlowStorageAdapterStub
    )

    assert {:ok, %{status: "succeeded"}} =
             Flow.run_inline(
               "publish_default",
               %{
                 "space_hash" => space.hash,
                 "embed_hash" => "LeDE9v86ye",
                 "input_url" => "https://example.com/video.mp4",
                 "source_body" => "stub-media-body",
                 "source_content_type" => "video/mp4",
                 "media_package_hls_variant_strict" => false,
                 "media_package_hls_audio_strict" => false,
                 "media_probe" => %{
                   "duration" => 10.0,
                   "size_bytes" => 15,
                   "filetype" => "mp4",
                   "aspect_ratio" => "16 / 9",
                   "streams" => []
                 }
               },
               space_pipeline: space
             )
  end

  describe "asking AI for a change" do
    test "shows the proposal in the editor and saves it once approved", %{conn: conn} do
      answer_with("I propose to stop making 4K.", [
        %{"action" => "turn_off", "step_id" => "video_h264_uhd"},
        %{"action" => "turn_off", "step_id" => "manifest"}
      ])

      {conn, space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")
      refute has_element?(view, "#pipeline-assistant-messages")

      assert ask(view, "Do not generate 4K for this space") =~ "Working out a proposal"

      render_async(view)
      assert has_element?(view, "#pipeline-assistant-message-0", "Do not generate 4K")
      assert_received {:request, request}
      assert request.message == "Do not generate 4K for this space"

      refute has_element?(view, "#pipeline-assistant-pending")
      assert has_element?(view, "#pipeline-assistant-message-1", "I propose to stop making 4K.")

      assert has_element?(
               view,
               "#pipeline-assistant-changes-1",
               "Turn off Transcode Video H264 UHD"
             )

      assert has_element?(
               view,
               "#pipeline-assistant-follows-1",
               "4 steps that depend on this follow"
             )

      assert has_element?(view, "#pipeline-assistant-follows-1", "Package HLS H264 UHD")

      assert has_element?(
               view,
               "#pipeline-assistant-rejected-1",
               "Build Manifest is required and stays on."
             )

      # The proposal is the editor's draft: same states, nothing saved yet.
      assert has_element?(view, "#pipeline-step-video_h264_uhd[data-state=disabled]")
      assert has_element?(view, "#pipeline-step-hls_h264_uhd[data-state=auto_disabled]")
      assert has_element?(view, "#pipeline-step-manifest[data-state=enabled]")
      assert has_element?(view, "#pipeline-proposed-video_h264_uhd")
      assert has_element?(view, "#pipeline-proposed-hls_h264_uhd")
      assert has_element?(view, "#pipeline-inspector-title", "Transcode Video H264 UHD")
      assert has_element?(view, "#pipeline-dirty")
      assert Pipelines.current(space) == nil

      view |> element("#pipeline-assistant-approve") |> render_click()

      assert %{version: 1, note: "AI: Do not generate 4K for this space", overrides: overrides} =
               Pipelines.current(space)

      assert overrides["disabled_steps"] == ["video_h264_uhd"]

      assert has_element?(
               view,
               "#pipeline-assistant-message-1",
               "Approved and saved as version 1"
             )

      refute has_element?(view, "#pipeline-assistant-approve")
      refute has_element?(view, "#pipeline-proposed-video_h264_uhd")
      refute has_element?(view, "#pipeline-dirty")
    end

    test "returns to the earlier draft when a proposal is dismissed", %{conn: conn} do
      answer_with("I propose to give the transcription the name.", [
        %{
          "action" => "set_setting",
          "step_id" => "transcribe_audio",
          "setting" => "context",
          "value" => "Northwind Studio"
        }
      ])

      {conn, space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")

      render_hook_toggle(view, "purge_cdn")
      ask(view, "Use our company name as context when transcribing")
      render_async(view)

      assert has_element?(view, "#pipeline-assistant-changes-1", "Northwind Studio")
      assert has_element?(view, "#pipeline-setting-transcribe_audio-context", "Northwind Studio")
      assert has_element?(view, "#pipeline-step-purge_cdn[data-state=disabled]")

      view |> element("#pipeline-assistant-dismiss") |> render_click()

      assert has_element?(view, "#pipeline-assistant-message-1", "Dismissed. Nothing was saved.")
      refute has_element?(view, "#pipeline-proposed-transcribe_audio")
      assert has_element?(view, "#pipeline-step-purge_cdn[data-state=disabled]")
      assert has_element?(view, "#pipeline-dirty")
      assert Pipelines.current(space) == nil

      view |> element("#pipeline-step-transcribe_audio") |> render_click()
      refute has_element?(view, "#pipeline-setting-transcribe_audio-context", "Northwind Studio")
    end

    test "answers without a proposal when nothing changes or the model fails", %{conn: conn} do
      answer_with("I can turn optional steps off or on.", [])
      {conn, space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")

      ask(view, "What can you do?")
      render_async(view)

      assert has_element?(view, "#pipeline-assistant-message-1", "I can turn optional steps")
      refute has_element?(view, "#pipeline-assistant-changes-1")
      refute has_element?(view, "#pipeline-assistant-approve")
      refute has_element?(view, "#pipeline-dirty")

      Application.put_env(:mave_core, :pipeline_assistant_stub, fn _request ->
        {:error, {:http_error, 503}}
      end)

      ask(view, "No 4K please")
      render_async(view)

      assert has_element?(view, "#pipeline-assistant-message-3", "Nothing was changed")
      refute has_element?(view, "#pipeline-dirty")
      assert Pipelines.current(space) == nil
    end

    test "keeps the request with an answer to the assistant's question", %{conn: conn} do
      answer_with("What is your company name?", [])
      {conn, space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")

      ask(view, "Use our company name as context")
      render_async(view)

      answer_with("I propose to add the name.", [
        %{
          "action" => "set_setting",
          "step_id" => "transcribe_audio",
          "setting" => "context",
          "value" => "Northwind Studio"
        }
      ])

      ask(view, "Northwind Studio")
      render_async(view)

      assert_received {:request, %{history: []}}
      assert_received {:request, %{message: "Northwind Studio", history: history}}

      assert history == [
               %{role: :user, text: "Use our company name as context"},
               %{role: :assistant, text: "What is your company name?"}
             ]

      view |> element("#pipeline-assistant-approve") |> render_click()

      assert %{note: "AI: Use our company name as context / Northwind Studio"} =
               Pipelines.current(space)
    end

    test "is hidden without a configured model or without edit access", %{conn: conn} do
      {conn, _space} = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, "/settings/encoding")
      refute has_element?(view, "#pipeline-assistant")
      refute has_element?(view, "#pipeline-assistant-notice")

      answer_with("Sure.", [%{"action" => "turn_off", "step_id" => "video_h264_uhd"}])
      Application.put_env(:mave_core, :usage_limits_backend, NoAssistant)
      {:ok, view, _html} = live(conn, "/settings/encoding")
      refute has_element?(view, "#pipeline-assistant")

      assert has_element?(
               view,
               "#pipeline-assistant-notice",
               "Ask AI for changes from the Pro plan."
             )

      # A crafted event does not reach the model either.
      view
      |> with_target("#encoding-pipeline")
      |> render_submit("assistant_ask", %{"assistant" => %{"request" => "No 4K"}})

      refute_received {:request, _request}

      Application.put_env(:mave_core, :usage_limits_backend, ManagedPipeline)
      {:ok, view, _html} = live(conn, "/settings/encoding")
      refute has_element?(view, "#pipeline-assistant")
      refute has_element?(view, "#pipeline-assistant-notice")
    end
  end

  defp answer_with(reply, operations) do
    test = self()

    Application.put_env(:mave_core, :pipeline_assistant_stub, fn request ->
      send(test, {:request, request})
      {:ok, %{reply: reply, operations: operations}}
    end)
  end

  defp ask(view, request) do
    view
    |> form("#pipeline-assistant-form", %{"assistant" => %{"request" => request}})
    |> render_submit()
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
