# Mave Core

Mave Core is a self-hosted video platform and Phoenix/OTP application named
`:mave_core`. Read `README.md` for the product overview, `CONTRIBUTING.md` for
local development and the code map. Technical references are linked there.

## Mave-specific guidance

- Use English for repository documentation, code comments, commit messages,
  branch names, and pull request titles/descriptions unless the user explicitly
  requests another language.
- Do not create or amend Git commits unless the user explicitly asks for a
  commit. Leave requested changes uncommitted by default.
- Keep Core independently buildable and self-hostable. Preserve public
  contracts and keep deployment-specific policy configurable.
- Main bounded areas live under `lib/mave_core`: accounts, analytics, assets,
  collections, embeds, flow, media, metrics, spaces, transcription, uploads, and
  workers.
- Web/API/live code lives under `lib/mave_core_web`. Dashboard UI should reuse
  `MaveCoreWeb.DashboardComponents` and the app layouts before inventing new UI
  primitives. Components live under `lib/mave_core_web/components/dashboard_components`;
  expose shared delegates in `dashboard_components.ex` and add examples under `storybook/`.
- Never read or output passwords and secrets.
- The flow engine is central to media processing. Read `docs/flow_engine.md` and
  `docs/flow_engine_internal.md` before changing flow schemas, steps, presets,
  or worker behavior.
- Webhook delivery design is in `docs/webhook_delivery_outbox.md`.

## Product architecture

The high-level runtime path is:

1. A dashboard user or API client creates an embed and receives a signed upload
   JWT scoped to a space, collection, or existing video.
2. `@maveio/components` connects to the Phoenix upload socket for progress and
   sends bytes directly to tusd using the resumable-upload protocol.
3. tusd stores the temporary object and calls the protected core upload hook.
4. `MaveCore.Uploads` validates the JWT again, resolves/creates the embed and
   asset version, and starts a versioned flow run.
5. Oban coordinates the flow DAG. Lightweight steps run in the app process;
   FFmpeg-heavy transfer/transcode/package steps run on isolated FLAME workers.
6. Outputs are written to the space's S3-compatible bucket. The flow persists
   relational metadata, publishes `manifest.json` and player assets, invalidates
   caches, broadcasts upload progress, and enqueues webhooks.
7. Browser components fetch the manifest and media directly from the per-space
   CDN, play through native media/HLS.js, and send playback events to the metrics
   ingest host. Dashboard analytics query those events from ClickHouse.

## Core runtime and supervision

`MaveCore.Application` builds the supervision tree according to
`MAVE_RUNTIME_ROLE` and whether the process is a FLAME child (`FLAME_PARENT`). A
normal app node starts telemetry, DNS clustering, PubSub, rate limiting, the
image-generation cache, PostgreSQL, ClickHouse, the metrics ingestion buffer,
the Phoenix endpoint, optional FLAME pools/prewarmers, and Oban. A FLAME child is
deliberately minimal: it executes the supplied work without starting databases,
the endpoint, Oban, cluster services, or another FLAME pool.

Larger installations can separate work using the same release in several roles:

| Role | Main responsibility | Oban queues | FLAME pool |
| --- | --- | --- | --- |
| `dashboard` | Browser auth and LiveView dashboard | disabled | disabled |
| `api` | Public API and upload socket/hook traffic | disabled | disabled |
| `image` | Dynamic image/poster origin | disabled | enabled by deployment |
| `ingest` | High-volume playback event ingestion | disabled | disabled |
| `worker` | Flow, webhook, recovery, and background jobs | enabled | enabled |

All non-FLAME roles can start the endpoint and repositories because they use a
common release. `MaveCore.Application.oban_runtime_config/2` keeps Oban available
for job insertion on request-serving nodes while disabling queue execution,
plugins, and peer leadership outside `worker`. The older `web`/default role is
still supported for local and deployment-compatibility use.

The important infrastructure consequence is that code must not assume every
request process also consumes jobs or owns a FLAME pool. Cross-node updates use
PostgreSQL/Oban and Phoenix PubSub; production nodes discover peers through the
DNS query configured by `DNS_CLUSTER_QUERY`.

## Domain model and ownership

The contexts under `lib/mave_core` are the public service layer. Controllers and
LiveViews should call contexts instead of assembling cross-context Ecto queries.

- `Accounts` owns users, login/session/invite tokens, Google OAuth integration,
  email validation, and notification delivery.
- `Spaces` is the tenant boundary. A space owns memberships, invites, domains,
  API keys, storage region/default flow selection, webhooks, and usage policy.
  API keys have read/write or read-only access; purpose-scoped keys are used for
  internal dashboard uploads.
- `Assets` models media identity and versions. An `Asset` belongs to a space,
  has many `Video` versions, and points at its current video. A video owns its
  renditions, subtitles, and alternate audio tracks.
- `Embeds` is the presentation/publication layer. An `Embed` belongs to a space,
  points to an asset or collection, owns player settings, and carries archive,
  replacement, and soft-deletion state. Do not collapse `Embed`, `Asset`, and
  `Video`: they represent public placement, durable media identity, and a
  particular uploaded/processed version respectively.
- `Collections` and `CollectionEmbed` form ordered folders/showcases. Collection
  embeds can be nested; move/archive/delete logic in `MaveCore.Embeds` protects
  against invalid trees and keeps membership positions consistent.
- `Flow` owns immutable templates/versions and mutable runs. `flow_runs`,
  `step_runs`, and `artifact_refs` are the execution ledger, while step handlers
  write media objects and later synchronize successful outputs into asset rows.
- `Uploads` joins tusd authorization, asset/embed creation or replacement,
  custom poster/audio/subtitle ingestion, flow startup, PubSub progress, usage
  limits, and webhook event creation.
- `Media` owns S3-compatible storage profiles, public/signed URLs, CDN purging,
  manifests/playlists, rendition sizing, and image generation coordination.
- `Metrics` validates and buffers playback events before batched ClickHouse
  inserts. `Analytics` and `Analytics.Video` query ClickHouse for space/video
  dashboards; PostgreSQL is not the analytics event store.
- `Transcription` wraps language detection and Mistral transcription/translation.
  These are optional flow branches and respect strict/non-strict step behavior.
- `Workers` contains Oban coordinators, step executors, webhook delivery,
  recovery, image processing, and FLAME prewarming. Keep scheduling policy in
  the flow/worker layer rather than hiding it in controllers.

PostgreSQL (`MaveCore.Repo`) is authoritative for accounts, tenant/media
metadata, flow state, Oban, and webhook outbox state. ClickHouse
(`MaveCore.ClickHouseRepo`) is authoritative for playback analytics. Object
storage is authoritative for original media, versioned renditions, HLS,
posters/storyboards/subtitles, `manifest.json`, and generated player HTML.

Primary IDs are UUIDs, with legacy short UUID compatibility where public
contracts require it. A normal public video embed id is the five-character
space hash plus the ten-character embed hash. Preserve the existing helpers
(`EmbedId`, `LegacyShortUUID`, and `SettingsSerializer`) instead of parsing or
constructing identifiers ad hoc.

## HTTP, hosts, and authentication

`MaveCoreWeb.Router` exposes one endpoint through host-specific pipelines. A
deployment can route each hostname to a matching runtime role.

- `MAVE_MANAGE_HOST` serves Google auth, login/logout, space invite flow, the
  authenticated LiveView dashboard, settings, video detail, flow diagnostics,
  subtitle downloads, and the `/api/v1/socket` upload WebSocket.
- `MAVE_API_HOST` serves `/v1` public video/collection/data endpoints. Equivalent
  `/api/v1` paths remain for compatibility. Standard API access uses a space key
  and secret via Basic auth or a base64-encoded Bearer credential.
- `MAVE_METRICS_HOST` accepts `POST /v1/events`. Payloads are validated, enriched
  with user-agent data, rate limited, buffered, and batch-inserted into
  ClickHouse; success is `202 Accepted`.
- `MAVE_IMAGE_HOST` serves the dynamic `/:mave_id` poster/image origin.
- tusd is a separate service on the upload hostname. Its internal callback is
  `POST /internal/upload-hooks/tusd`, authenticated by
  `MAVE_UPLOAD_HOOK_SECRET` and a signed upload JWT inside tus metadata.
- `/health` is the Kubernetes health endpoint. Maintenance mode deliberately
  allows health, upload-hook, metrics-ingest, login/logout, selected auth paths,
  image origins, and authorized internal users as configured by the pipelines.

Browser authentication uses a signed cookie session, persisted session tokens,
and LiveView `on_mount` hooks. Token-login URLs are single-purpose and sanitize
return paths. Flow administration is a separate session-based allowlist
(`:flow_admin` email/domain config); state-changing flow requests also require
CSRF. Never replace these boundaries with controller-local checks.

API writes must honor `Space.Key.access_level`. Upload tokens are HS256 JWTs
signed with the displayed API key/secret, expire, and carry a `sub` identifying
the permitted space/collection/video. Both the Phoenix upload socket and the
tusd hook revalidate current key access, so changing a key to read-only takes
effect for already-issued JWTs.

## Media flow engine

Read `docs/flow_engine.md` and `docs/flow_engine_internal.md` before modifying
this subsystem. Its core rules are:

- Step types and their executor/category/options live in code in
  `MaveCore.Flow.StepRegistry`.
- Built-in presets live in `MaveCore.Flow.Presets`, but runs never execute the
  registry map directly. Installing a preset creates a database template and an
  immutable checksum-addressed version; unchanged installs are idempotent.
- A run snapshots the chosen version and materializes one `StepRun` per DAG
  node. `FlowCoordinatorWorker` reconciles dependencies and schedules ready
  nodes; `FlowStepWorker` claims and executes one node idempotently.
- Fair lanes map work onto separate Oban queues. Required-step failure fails the
  run; optional/non-strict branches may become skipped or unavailable without
  blocking publication. Retry/recovery code must preserve this distinction.
- Heavy storage/FFmpeg steps execute through FLAME. Inline execution is for
  orchestration and tests, not a production fallback for failed FLAME capacity.
- `publish_default` resolves/copies the source, probes it, creates an H.264
  ladder and optional higher/alternate outputs, packages HLS, extracts visual
  assets, optionally transcribes/translates, builds the master manifest, purges
  CDN state, and emits completion notifications. `publish_local` is the lighter
  development preset.
- Flow artifacts are immutable references to produced objects. `manifest.json`
  is the browser contract and media normally lives under `<embed_hash>/vN/` in
  the space bucket. Keep old-version reads working when changing object layout.
- Successful processing updates `Asset.current_video`, video metadata,
  renditions/subtitles/audio tracks, embed status, manifests, PubSub events, and
  webhook outbox entries. A step is not complete merely because FFmpeg exited.

Use `source_body`, `media_probe`, inline execution, and the test storage adapters
for deterministic tests. Migration/debug `*_mode`, `*_strict`, direct-storage,
and timeout knobs are documented in `docs/flow_engine_internal.md`; do not make
them part of ordinary product behavior without a compatibility reason.

## Webhook delivery

Domain actions enqueue one persisted `space_webhook_deliveries` row per enabled
destination/event. `WebhookDeliveryWorker` claims the row, signs and sends the
payload, records the response snapshot, and schedules retry state. The outbox is
both retry source and audit trail; do not send webhooks directly from request or
flow code. Supported video lifecycle events are defined by
`MaveCore.Spaces.Webhook`, and compatibility details live in
`docs/webhook_delivery_outbox.md`.

## Browser components contract

The public `@maveio/components` package is published as ESM/CJS plus type declarations.
The main package exports `mave-player`, `mave-clip`, `mave-img`, `mave-text`,
`mave-list`, `mave-pop`, `mave-files`, and `mave-upload`; `dist/react.js` and
`dist/vue.js` provide framework wrappers. Lit owns rendering, Media Chrome owns
player controls, HLS.js handles adaptive playback, `@maveio/data` emits metrics,
the Phoenix JS client carries upload progress, and `tus-js-client` uploads bytes.

The component runtime has four configurable endpoints:

- `api.endpoint`: public/legacy API and collection metadata.
- `cdn.endpoint`: template for a per-space media origin; `${this.spaceId}` is
  replaced from the first five characters of the embed id.
- `metrics.endpoint`: playback event ingestion.
- `upload.endpoint` and `upload.socket`: tusd bytes and Phoenix progress events.

`MaveCore.Embeds.SettingsSerializer` is the server-side source of those values,
snippet URLs, player attributes, poster URLs, and public embed ids. Dashboard
previews dynamically import `dist/config.js`, call `configureMave`, then import
the selected component bundle. Generated `player.html` does the same. Production
defaults point at `cdn.video-dns.com`; `MAVE_COMPONENTS_SRC` overrides the exact
entry module and `MAVE_COMPONENTS_BASE_URL` points at a self-hosted bundle.

The normal player does not request core for every playback. `EmbedController`
loads `<space CDN>/<embed>/manifest.json` with bounded retry, then resolves
versioned media paths. Therefore manifest fields, rendition enums, status values,
audio/subtitle paths, cache behavior, and public object layout are shared
contracts between `core` and `components`. When changing one, inspect and test
the other in the same task.

The upload component first opens `embed:<token>` on `/api/v1/socket`; the server
returns a unique `upload_id` and subscribes that channel to PubSub. The component
adds `token`, `upload_id`, title, and content type to tus metadata, supports
resumption, and translates server `rendition`, `completed`, and `error` pushes
into DOM events. Keep metadata/event names backward compatible. The self-hosted
bundle enables tusd `pre-create`, `post-receive`, and
`post-finish`. Preserve the pre-create authorization check when configuring a
different upload service.

Core uses the hosted components by default. Browser-package development is
separate; see the public [components repository](https://github.com/maveio/components).
Do not require a sibling checkout to build or run Core.

## Compatibility checklist

When changing a shared contract, verify:

- manifest JSON, media object paths, and endpoint defaults against browser consumers;
- upload JWT scope, tus metadata, socket events, hooks, and API-key access levels;
- API routes, host routing, CORS, and CSP against generated snippets;
- queues, FLAME pools, and runtime roles against `MaveCore.Application`;
- migrations, release migration execution, and compatibility with existing data.

Never run deployment, secret synchronization, or production migration commands
merely to validate a local Core edit. Use disposable test services and the
self-hosted smoke test where appropriate.

## Local commands

Run from the `core` repository root. Use the Docker Compose services documented
in `CONTRIBUTING.md`; do not assume a particular shell or Docker host.
Do not restart a running development environment or use production data for
validation. Run tests against disposable services.

```bash
mix test
mix credo --strict
mix security
mix security.enforce
mix precommit
```

Useful targeted commands:

```bash
mix test test/path/to/file_test.exs
mix test --failed
mix flow.manifest.parity /tmp/mave-manifest.json /tmp/core-manifest.json
```

Notes:

- `mix test` ensures ClickHouse test DB setup and Ecto migrations through the
  project alias.
- The compose app container may run with dev defaults, so use
  `MIX_ENV=test mix test` inside Docker when needed.
- `mix security` runs Sobelow in compact/private mode with the current project
  ignores listed in `mix.exs`; use `mix security.enforce` when a failing threshold
  is required.

## Data and service boundaries

- PostgreSQL uses `MaveCore.Repo`.
- ClickHouse uses `MaveCore.ClickHouseRepo` and powers analytics/data endpoints.
- Background processing uses Oban workers and FLAME for media/flow work.
- Local development services include Postgres, MinIO, ClickHouse, and tusd via
  Docker Compose.
- Upload hooks enter through `POST /internal/upload-hooks/tusd` and should stay
  protected by `MAVE_UPLOAD_HOOK_SECRET`.
- Public API authentication should use the existing API key/secret plugs and
  context functions.

## Testing conventions

- Use `MaveCore.DataCase` for data-layer tests and `MaveCoreWeb.ConnCase` for
  controller/API/LiveView tests.
- `ConnCase` builds a plain connection; add explicit API keys, hook secrets, or
  authenticated sessions in tests that need them.
- Prefer targeted tests near the changed context. For LiveView, assert on stable
  IDs/selectors with `Phoenix.LiveViewTest` helpers rather than brittle raw HTML.
- Start supervised processes in tests with `start_supervised!/1`; avoid
  `Process.sleep/1`.

## Phoenix project guidelines

The following rules are the existing Phoenix usage guidance for this app.

### General Phoenix guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
