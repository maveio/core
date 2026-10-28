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
- Keep changes independently useful, buildable, and configurable for
  contributors and self-hosters. Examples and documentation should stand on
  their own and use material that can be shared publicly.
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
- Use focused local checks when implementing or debugging a change. Rely on
  GitHub Actions for full test suites, lint, and security checks covered there;
  do not rerun them locally merely to prepare a PR. Run additional checks for
  uncovered behavior or environments, or when CI is unavailable. Review any
  formatting/lockfile changes produced by aliases. See CONTRIBUTING for setup.

## Pull request presentation

Write for a contributor or self-hoster who has not read the task conversation.
A reader should understand the problem and the improvement within twenty seconds.

- Use an English title that names the resulting behavior, such as "Show upload
  progress until processing starts". Avoid vague titles and implementation-only
  descriptions when the user-facing effect is clearer.
- Open with one or two plain sentences: what happens today, what changes, and
  why that matters. Follow with two to four concrete bullets when useful.
  Describe the final change, not the sequence of work or a list of edited files.
- Use the GitHub PR template as a starting point. Short headings, modest emoji
  markers, and small before/after tables are welcome; avoid decorative noise,
  oversized headings, and long checklists. Remove empty or irrelevant sections.
  Routine PRs should usually fit in roughly 100–200 words, excluding media.
- For visible UI or media changes, capture real before/after screenshots. Use a
  short video or GIF when motion or interaction is the point. Label the states,
  keep the viewport and example consistent, and inspect the media before posting.
  Put the preview close to the summary so readers can see the improvement quickly.
- Use synthetic examples and publicly shareable fixtures in previews. Check
  the entire frame, browser chrome, filenames, and audio for personal data,
  credentials, and other confidential information before publishing.
- Attach media where GitHub readers can actually view it. Local filesystem paths
  and inaccessible artifact links are not previews. Never substitute a mockup or
  generated illustration for evidence that the implementation works. If capture
  or attachment is unavailable, state that limitation rather than claiming proof.
- For changes without a visual result, use the smallest helpful example: an API
  request/response, a reproduction, or a before/after behavior table. Do not force
  screenshots onto dependency updates or invisible backend changes.
- Let GitHub's Checks tab report routine CI results. Do not repeat its test
  counts, command lists, or "CI passed" checklist in the PR body, and do not rerun
  the same suites locally just to write that section.
- First verify that CI covers the changed code and the relevant revision and
  dependencies. Focused local tests remain useful during implementation, for
  debugging, or for gaps such as visual behavior, real codecs, and performance.
- Add an optional additional-checks section only for evidence beyond routine CI:
  a manual reproduction, browser/device checks, benchmarks, or a material gap or
  failure reviewers need to understand. Remove it when it adds nothing. Never
  imply pending checks passed; a green scan is not proof of complete security.
- Performance and encoding claims need a baseline, units, test conditions, and
  tradeoffs. Use public-safe measurements, and distinguish measured results from
  expectations. Do not imply every input improves because the average improved.
- Include compatibility or upgrade guidance when contributors and self-hosters
  need it. Explain prerequisites and behavior using the project's own public
  documentation so readers can understand and reproduce the change.
- Before publishing or updating a PR, read the rendered body, verify media and
  links, and rewrite the title and summary if the final scope has changed.

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
