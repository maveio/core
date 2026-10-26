# Mave Core

Public, self-hostable Phoenix/OTP application (`:mave_core`). Read
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, commands and the code map;
[README.md](README.md) describes the product and self-hosted quickstart.

## Working rules

- Check `git status --short` before editing. Preserve unrelated changes and
  local work. Do not create or amend commits unless the user requests it.
- Deliver changes on a task branch through a pull request; never push directly
  to the default branch. Merging and releasing require separate authorization.
- Use English for code comments, documentation, branches and pull requests.
- Core is public: keep customer identifiers, production observations, private
  infrastructure details, billing, hosted policy and legacy import tooling out.
  Those belong in the private host application.
- Keep Core independently buildable and configurable for self-hosters. Do not
  require sibling repositories or private services.
- Use `rg` for searches; exclude `deps`, `_build`, `node_modules` and generated
  output unless those directories are the subject of the task.
- Do not restart a running development environment or use production data to
  validate a change. Use dedicated test services and synthetic fixtures.

## Changes and validation

- Prefer small, behavior-focused changes with deterministic tests near the code.
- Use contexts from `lib/mave_core` for domain work; controllers and LiveViews
  should not assemble cross-context database queries.
- Preserve the distinction between `Embed` (placement), `Asset` (media identity)
  and `Video` (version). Reuse existing ID and serialization helpers.
- Preserve space isolation, key access levels, upload authorization, manifests,
  object paths, socket events and webhook contracts. Check browser consumers
  when changing a shared media or API contract.
- Reuse existing plugs and configuration helpers for authentication, CORS, CSP,
  host routing and upload hooks. Never log secrets, tokens or signed URLs, and
  never convert external input with `String.to_atom/1`.
- Run focused tests, `mix credo --strict`, `mix security.enforce` and
  `mix precommit` as appropriate. Review formatting/lockfile changes produced by
  aliases. See CONTRIBUTING for integration and self-hosted smoke tests.
- In the multi-repository workspace, use the host application's runtime and
  test entry point for hosted-product work. Use Core directly for standalone work.

## Phoenix conventions

- Reuse `MaveCoreWeb.DashboardComponents` and existing layouts. Add reusable
  components to their existing module and storybook rather than new UI systems.
- Use HEEx, `<.input>`, `to_form/2`, `<.link navigate={...}>` and
  `<.link patch={...}>`. Add stable DOM IDs for interactive elements and tests.
- Use LiveView streams for changing collections. A JS hook needs a unique DOM ID;
  hooks that own their DOM also need `phx-update="ignore"`. Use colocated hooks
  or the existing JS bundle rather than raw inline scripts.
- Use the existing `Req` HTTP client and `start_supervised!/1` in tests.
  Synchronize tests with process messages/monitors instead of sleeps.
- Prefer Ecto changesets and existing query helpers. Preload associations used
  in templates and keep server-owned fields out of user-controlled casts.
- Use the existing Tailwind setup; do not add a second component framework or
  external script/style tags to layouts.

## References and documentation

Read the relevant reference before changing these contracts:

- [Flow engine](docs/flow_engine.md): versioned processing, step behavior and debugging.
- [Webhook delivery](docs/webhook_delivery_outbox.md): delivery state and retries.
- [Prepared analytics](docs/analytics_sessions.md): activation and data lifecycle.
- [Private playback](docs/private_playback.md) and [media isolation](docs/media_security.md).
- [Self-hosting](deploy/self-hosted/README.md) and [encoding boosters](deploy/encoding-booster/README.md).

Update documentation when a reader's setup, usage or public contract changes.
Prefer an existing reference and links to source/docstrings. Do not add session
journals, implementation inventories, benchmark reports or completed migration
plans to public docs. Avoid duplicating code, tests or upstream framework manuals.
