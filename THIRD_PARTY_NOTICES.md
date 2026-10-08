# Third-party notices

Third-party code and assets retain their own licences and copyright notices.
This document records the notices verified for the components below. It is not a
complete dependency SBOM, a clearance of every repository asset, or a declaration
that a built container meets all redistribution obligations.

## MIT-licensed frontend and framework material

The copyright notices in this table and the MIT licence text below apply to the
respective works, not to Core as a whole.

| Component | Use in Core | Copyright notice | Source |
| --- | --- | --- | --- |
| topbar 3.0.0 | Vendored progress bar in `assets/vendor/topbar.js` | Copyright (c) 2024 Buu Nguyen | [Upstream](https://github.com/buunguyen/topbar); licence and copyright in the vendored file header |
| daisyUI 5.0.35 | Vendored Tailwind plugins in `assets/vendor/daisyui.js` and `assets/vendor/daisyui-theme.js` | Copyright (c) 2020 Pouya Saadeghi | [Versioned licence](https://github.com/saadeghi/daisyui/blob/v5.0.35/LICENSE) |
| Heroicons 2.2.0 | Icons installed through `mix.exs` and compiled into dashboard styles | Copyright (c) Tailwind Labs, Inc. | [Versioned licence](https://github.com/tailwindlabs/heroicons/blob/v2.2.0/LICENSE) |
| Phoenix | Framework and generated application scaffolding | Copyright (c) 2014 Chris McCord | [Upstream](https://github.com/phoenixframework/phoenix); `LICENSE.md` in the resolved Phoenix dependency |
| LottieFiles Lottie Player 2.0.12 | Dashboard animation player from `assets/package-lock.json` | Copyright (c) 2019 LottieFiles.com | [Upstream](https://github.com/LottieFiles/lottie-player); `LICENSE` in the resolved npm package |
| Chart.js 4.5.1 | Dashboard charts from `assets/package-lock.json` | Copyright (c) 2014-2024 Chart.js Contributors | [Upstream](https://github.com/chartjs/Chart.js); `LICENSE.md` in the resolved npm package |

### MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Dependency and data sources

- [mix.exs](mix.exs) and [mix.lock](mix.lock) identify the Elixir dependencies and
  resolved versions, including the separately licensed framework, runtime, and
  build tooling. Preserve each dependency's own licence and notice files when
  distributing its code or binaries.
- [assets/package.json](assets/package.json) and
  [assets/package-lock.json](assets/package-lock.json) identify the direct and
  transitive npm dependencies. The direct-package notices above do not replace
  the notices required by their dependencies.
- `mix ua_inspector.download` fetches parser data from
  [Matomo Device Detector 6.5.0](https://github.com/matomo-org/device-detector/tree/6.5.0),
  licensed under LGPL-3.0-or-later. The YAML source is included in `priv/ua_inspector` in
  the release. Its [licence and notice](deploy/licenses/device-detector/) are
  bundled separately from UAInspector's library licence.
- Browsers load `@maveio/components` and its `@maveio/data` dependency from the
  hosted CDN by default. Their source and licence notices belong to the separate
  [components](https://github.com/maveio/components) and
  [data](https://github.com/maveio/data) projects. They are not built locally by
  this repository's self-hosted bundle.

## Media sandbox

The parser launcher dynamically links to [libseccomp](https://github.com/seccomp/libseccomp),
licensed under LGPL-2.1-only. It uses the distribution's library package; the
launcher source and build commands are included in this repository. Preserve the
library's licence notices and source availability when redistributing images.

## Containers and FFmpeg

The [Dockerfile](Dockerfile) defines the release image's system packages and
FFmpeg build. FFmpeg is configured with `--enable-gpl`, including libraries such
as x264 and x265; do not describe this build as LGPL-only. See
[FFmpeg's licensing guidance](https://ffmpeg.org/legal.html).

The image keeps Core's licence, dependency notice files and lockfiles under
`/app/licenses`, FFmpeg licence texts under `/opt/ffmpeg/share/licenses`, and the
verified FFmpeg source archive and build configuration under
`/opt/ffmpeg/share/source`. Ubuntu package notices remain in `/usr/share/doc`.

This collection is not a complete runtime SBOM or source bundle: the exact
native Rust features, Erlang/Elixir runtime, and system-library source delivery
still require release-specific verification before redistributing an image.

The PostgreSQL, ClickHouse, MinIO, MinIO Client, tusd, and Caddy services in
[the self-hosted Compose file](deploy/self-hosted/compose.yml) use upstream
software with its own terms. MinIO and MinIO Client are built from pinned source
releases by [their Dockerfile](deploy/minio/Dockerfile), which retains their
licence files under `/licenses`. Inclusion in a Compose file does not relicense
these services under Core's licence.

## Fonts, artwork, and marks

Core's default styles use a system-font stack; no font download is required for
that stack. Third-party font licences must be checked independently if a
deployment supplies custom fonts.

The Mave artwork bundled with Core is approved for distribution with the project.
This does not grant rights to use Mave trademarks for other products.

## Documentation images

The dashboard screenshots include approved stills from the mave.io demo videos
Craftsmanship, The Alps, and Whales. The footage is not covered by Core's AGPL.

The README's Mave wordmarks do not grant rights to use Mave trademarks for other
products.

The [pipeline illustration](docs/images/video-pipeline.svg) is under the
[repository licence](LICENSE). It uses Figtree by The Figtree Project Authors under the
[SIL Open Font License 1.1](https://github.com/google/fonts/blob/main/ofl/figtree/OFL.txt).
