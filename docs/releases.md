# Releases

Run **Actions → Release Core** on `main` and choose **patch**, **minor** or
**major**. The first release uses `0.1.0`; later releases update `mix.exs`
automatically. Until 1.0, minor releases may include breaking changes.

The workflow tests the selected version, including a fresh self-hosted install,
then publishes its commit, tag and GitHub Release. If `main` changes during
checks, start a new run. Tags are never overwritten. Review the generated notes
for API, configuration and migration changes.

These are source releases, not Hex packages or prebuilt images. Self-hosters
can check out a release tag and use Docker Compose. Core releases do not deploy
the hosted service; consumers choose when to update their pinned Core version.
