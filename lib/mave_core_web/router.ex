defmodule MaveCoreWeb.Router do
  use MaveCoreWeb, :router
  import MaveCoreWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_current_user
    plug MaveCoreWeb.Plugs.InstallationSetup

    plug MaveCoreWeb.Plugs.Maintenance,
      allowed_paths: ["/health", "/login", "/logout"],
      allowed_path_prefixes: ["/auth/"],
      allowed_host_env_vars: ["MAVE_IMAGE_HOST"],
      allow_internal_users: true

    plug :fetch_live_flash
    plug :put_root_layout, html: {MaveCoreWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers
    plug MaveCoreWeb.BrowserSecurity
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_current_user_from_session

    plug MaveCoreWeb.Plugs.Maintenance,
      allowed_paths: [
        "/v1/events",
        "/internal/encoding-booster/hls-uploads",
        "/internal/upload-hooks/tusd"
      ],
      allow_internal_users: true
  end

  pipeline :public_cors do
    plug MaveCoreWeb.Plugs.CORS
  end

  # JSON sendBeacon requests use credentials mode. This endpoint deliberately
  # does not fetch a session or resolve a user; its response is always anonymous.
  pipeline :metrics_api do
    plug MaveCoreWeb.Plugs.CORS, allow_beacon: true
    plug :accepts, ["json"]
  end

  pipeline :api_key_auth do
    plug MaveCoreWeb.Plugs.ApiKeyAuth
  end

  pipeline :api_host do
    plug MaveCoreWeb.Plugs.RequireHost, env_var: "MAVE_API_HOST"
  end

  pipeline :flow_admin_api do
    plug :fetch_session
    plug :fetch_current_user
    plug MaveCoreWeb.Plugs.FlowAdminAuth
  end

  pipeline :manage_host do
    plug MaveCoreWeb.Plugs.RequireHost, env_var: "MAVE_MANAGE_HOST"
  end

  pipeline :redirect_if_authenticated do
    plug :redirect_if_user_is_authenticated
  end

  pipeline :authenticated_user do
    plug :require_authenticated_user
  end

  pipeline :metrics_host do
    plug MaveCoreWeb.Plugs.RequireHost, env_var: "MAVE_METRICS_HOST"
  end

  pipeline :image_host do
    plug MaveCoreWeb.Plugs.RequireHost, env_var: "MAVE_IMAGE_HOST"
  end

  scope "/api/v1", MaveCoreWeb do
    pipe_through [:public_cors]
    get "/playback/media/:id/*path", Api.PlaybackController, :show, log: false
    options "/playback/media/:id/*path", Api.PlaybackController, :show, log: false
  end

  scope "/v1", MaveCoreWeb do
    pipe_through [:api_host, :public_cors]
    get "/playback/media/:id/*path", Api.PlaybackController, :show, log: false
    options "/playback/media/:id/*path", Api.PlaybackController, :show, log: false
  end

  scope "/", MaveCoreWeb do
    pipe_through :browser

    get "/health", PageController, :health, log: false
  end

  # Other scopes may use custom stacks.
  scope "/", MaveCoreWeb do
    pipe_through [:metrics_host, :metrics_api]

    options "/v1/events", Api.Data.EventsController, :create
    post "/v1/events", Api.Data.EventsController, :create
  end

  scope "/", MaveCoreWeb do
    pipe_through [:api]

    post "/internal/encoding-booster/hls-uploads",
         Api.EncodingBoosterHLSUploadController,
         :create

    post "/internal/upload-hooks/tusd", Api.Upload.TusdHooksController, :create
  end

  scope "/api", MaveCoreWeb do
    pipe_through [:public_cors, :api]

    scope "/v1" do
      options "/cli/authorizations", Api.CliAuthorizationsController, :create
      options "/cli/authorizations/token", Api.CliAuthorizationsController, :exchange
      post "/cli/authorizations", Api.CliAuthorizationsController, :create
      post "/cli/authorizations/token", Api.CliAuthorizationsController, :exchange

      options "/collection", Api.LegacyEmbedController, :collection, log: false
      get "/collection", Api.LegacyEmbedController, :collection, log: false
      options "/collection/:token", Api.LegacyEmbedController, :collection
      get "/collection/:token", Api.LegacyEmbedController, :collection

      options "/videos/:embed_hash/:token", Api.LegacyEmbedController, :delete_video
      delete "/videos/:embed_hash/:token", Api.LegacyEmbedController, :delete_video
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:api_host, :public_cors, :api]

    scope "/v1" do
      options "/cli/authorizations", Api.CliAuthorizationsController, :create
      options "/cli/authorizations/token", Api.CliAuthorizationsController, :exchange
      post "/cli/authorizations", Api.CliAuthorizationsController, :create
      post "/cli/authorizations/token", Api.CliAuthorizationsController, :exchange

      options "/collection", Api.LegacyEmbedController, :collection, log: false
      get "/collection", Api.LegacyEmbedController, :collection, log: false
      options "/collection/:token", Api.LegacyEmbedController, :collection
      get "/collection/:token", Api.LegacyEmbedController, :collection

      options "/videos/:embed_hash/:token", Api.LegacyEmbedController, :delete_video
      delete "/videos/:embed_hash/:token", Api.LegacyEmbedController, :delete_video
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:api, :flow_admin_api]

    get "/v1/flow/step-types", Api.Flow.StepTypesController, :index
    get "/v1/flow/presets", Api.Flow.PresetsController, :index
    post "/v1/flow/presets/:slug/install", Api.Flow.PresetsController, :install
    post "/v1/flow/templates", Api.Flow.TemplatesController, :create
    post "/v1/flow/templates/:template_id/versions", Api.Flow.VersionsController, :create
    post "/v1/flow/runs", Api.Flow.RunsController, :create
    get "/v1/flow/runs/:id", Api.Flow.RunsController, :show
  end

  scope "/api", MaveCoreWeb do
    pipe_through [:public_cors, :api, :api_key_auth]

    scope "/v1" do
      for path <-
            ~w(/videos /videos/:hash /videos/:hash/data /videos/owner/:hash /collections /collections/:hash /spaces/:space_hash/data) do
        options path, Api.VideosController, :index
      end

      get "/videos", Api.VideosController, :index
      get "/videos/:hash", Api.VideosController, :show
      post "/videos", Api.VideosController, :create
      put "/videos/:hash", Api.VideosController, :update
      delete "/videos/:hash", Api.VideosController, :delete
      get "/videos/owner/:hash", Api.VideosController, :owner

      get "/collections", Api.CollectionsController, :index
      post "/collections", Api.CollectionsController, :create
      put "/collections/:hash", Api.CollectionsController, :update
      delete "/collections/:hash", Api.CollectionsController, :delete

      get "/videos/:embed_id/data", Api.Data.VideosController, :show
      get "/spaces/:space_hash/data", Api.Data.SpacesController, :show
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:api_host, :public_cors, :api, :api_key_auth]

    scope "/v1" do
      for path <-
            ~w(/videos /videos/:hash /videos/:hash/data /videos/owner/:hash /collections /collections/:hash /spaces/:space_hash/data) do
        options path, Api.VideosController, :index
      end

      get "/videos", Api.VideosController, :index
      get "/videos/:hash", Api.VideosController, :show
      post "/videos", Api.VideosController, :create
      put "/videos/:hash", Api.VideosController, :update
      delete "/videos/:hash", Api.VideosController, :delete
      get "/videos/owner/:hash", Api.VideosController, :owner

      get "/collections", Api.CollectionsController, :index
      post "/collections", Api.CollectionsController, :create
      put "/collections/:hash", Api.CollectionsController, :update
      delete "/collections/:hash", Api.CollectionsController, :delete

      get "/videos/:embed_id/data", Api.Data.VideosController, :show
      get "/spaces/:space_hash/data", Api.Data.SpacesController, :show
    end
  end

  scope "/api", MaveCoreWeb do
    pipe_through [:public_cors, :api]

    scope "/v1" do
      options "/:embed_id", Api.LegacyEmbedController, :embed
      get "/:embed_id", Api.LegacyEmbedController, :embed
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:api_host, :public_cors, :api]

    scope "/v1" do
      options "/:embed_id", Api.LegacyEmbedController, :embed
      get "/:embed_id", Api.LegacyEmbedController, :embed
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:browser, :manage_host]

    get "/setup", SetupController, :show
    post "/setup", SetupController, :create

    get "/auth/:provider", OAuthController, :request
    get "/auth/:provider/callback", OAuthController, :callback

    delete "/logout", UserSessionController, :delete

    live_session :space_invite,
      root_layout: {MaveCoreWeb.Layouts, :auth},
      on_mount: [{MaveCoreWeb.UserLiveAuth, :optional_no_default_space}] do
      live "/space", SpaceInvite.Index, :index
    end

    live_session :dashboard,
      root_layout: {MaveCoreWeb.Layouts, :dashboard_root},
      layout: {MaveCoreWeb.Layouts, :dashboard},
      on_mount: [{MaveCoreWeb.UserLiveAuth, :authenticated}] do
      live "/", Dashboard.Videos.Index, :index
      live "/videos", Dashboard.Videos.Index, :index
      live "/videos/:id", Dashboard.Videos.Show, :show
      live "/data", Dashboard.Data.Index, :index
      live "/settings", Dashboard.Settings.Index, :general
      live "/settings/developer", Dashboard.Settings.Index, :developer
      live "/settings/team", Dashboard.Settings.Index, :team
      live "/settings/:tab", Dashboard.Settings.Index, :custom_tab
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:browser, :manage_host, :redirect_if_authenticated]

    live_session :auth,
      root_layout: {MaveCoreWeb.Layouts, :auth},
      on_mount: [{MaveCoreWeb.UserLiveAuth, :redirect_if_authenticated}] do
      live "/login", Auth.Index, :login
      live "/signup", Auth.Index, :signup
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:browser, :manage_host]

    live_session :dashboard_scoped,
      root_layout: {MaveCoreWeb.Layouts, :dashboard_root},
      layout: {MaveCoreWeb.Layouts, :dashboard},
      on_mount: [{MaveCoreWeb.UserLiveAuth, :authenticated}] do
      live "/flow/runs", Dashboard.Flow.Runs, :index
      live "/:space_id/videos", Dashboard.Videos.Index, :index
      live "/:space_id/videos/:id", Dashboard.Videos.Show, :show
      live "/:space_id/data", Dashboard.Data.Index, :index
      live "/:space_id/settings", Dashboard.Settings.Index, :general
      live "/:space_id/settings/developer", Dashboard.Settings.Index, :developer
      live "/:space_id/settings/team", Dashboard.Settings.Index, :team
      live "/:space_id/settings/:tab", Dashboard.Settings.Index, :custom_tab
    end
  end

  scope "/", MaveCoreWeb do
    pipe_through [:browser, :manage_host, :authenticated_user]

    live_session :cli_auth,
      root_layout: {MaveCoreWeb.Layouts, :auth},
      on_mount: [{MaveCoreWeb.UserLiveAuth, :authenticated}] do
      live "/cli/auth", CliAuthLive, :enter
      live "/cli/auth/:user_code", CliAuthLive, :authorize
    end

    get "/videos/:id/subtitles/:subtitle_id/download", Dashboard.SubtitleController, :download

    get "/:space_id/videos/:id/subtitles/:subtitle_id/download",
        Dashboard.SubtitleController,
        :download
  end

  use MaveCoreWeb.DevRoutes

  scope "/", MaveCoreWeb do
    pipe_through [:image_host, :public_cors]

    options "/:mave_id", Api.ImageController, :show
    get "/:mave_id", Api.ImageController, :show
  end
end
