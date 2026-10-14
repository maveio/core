# Translating existing subtitles

The video settings panel accepts one source subtitle and multiple target languages.
Each target creates an independent `translate_subtitle` flow. Existing languages,
the source language, and languages with an active translation are unavailable.
Requests are serialized on the video's asset row so concurrent requests cannot
create duplicate active translations. Translation waits until the normal video
publishing flow has finished, including its background branches.

`MaveCore.Transcription.SubtitleTranslations.request/5` is the tenant-scoped
service boundary. It checks ownership, the current video, source ownership,
language availability, and the usage policy before starting any flow. A rejected
multi-language request creates no partial set of runs. The dashboard displays
queued/running, completed, and failed results; failed languages can be requested
again.

The source can be timed transcription JSON (`segments` containing `start`, `end`,
and `text`), WebVTT, or SRT. UTF-8 input is limited to 5 MiB. VTT cue identifiers,
cue settings, and SRT sequence numbers are normalized away; text and cue start/end
times are preserved. Invalid, empty, untimed, and backwards cues fail explicitly.
Translation output must contain the same number of cues. Source times override
provider times, including cues shorter than 100 ms.

## Flow and storage

The internal preset has three required steps:

1. `subtitle.load_translation_source` reads only the source video's object prefix
   and writes normalized JSON for the existing translation step.
2. `ai.translate_subtitles` uses the configured translation provider with strict
   failure handling and the requested language.
3. `subtitle.publish_translation` adds only the new subtitle row and refreshes HLS
   and the existing manifest. It does not invoke the general flow finalizer or
   replace video, rendition, audio, or existing subtitle records.

Normal flow subtitle synchronization also retains rows marked `translated` and
skips conflicting generated languages. It locks the same asset row used by
selective publication. This protects translations from delayed post-step updates
and later re-finalization of the original publishing run.

The preset is deliberately absent from the upload-preset picker. The run snapshots
the video ID, object version, source ID/path, language, and a unique translation ID.
Its objects live under `<embed>/vN/translations/<translation-id>/` (without `vN`
for legacy version zero). Existing object paths are not reused. Source loading,
provider execution, and publication check the current video. Publication locks
the asset row while checking and updating it, so replacement cannot publish old
results onto the new version.

HLS refresh uses strict storage error handling. A failed HLS/manifest write fails
the finalizer and rolls back the new database row; existing rows remain intact.
Object-store writes are not transactional with PostgreSQL: generated objects can
remain after failure, and retrying the finalizer safely reuses its own output.
Videos with no HLS variants still receive an updated manifest. Publication is
idempotent for the same output, and rejects a different existing target track.

Public and private playback retain the existing storage architecture. Private HLS
rewriting normalizes internal relative references within the authorized embed,
then signs the resolved object URL. References escaping the embed and direct
requests containing dot segments are rejected. Media bytes continue to load from
storage.

## Optional host policy and migration

Hosts may implement the optional `MaveCore.UsageLimits` callback:

```elixir
def can_translate_subtitles?(space, %{video_id: video_id, target_languages: languages}) do
  MyHost.Usage.allow_subtitle_translation(space, video_id, languages)
end
```

It is checked at request time and again during execution, including immediately
before calling the translation provider. Self-hosting and older host adapters
default to `:ok` when the callback is absent. Provider configuration remains the
existing `:subtitle_translation_provider` setting; no additional provider is
required.

Migration `20261014144645_add_subtitle_source` adds nullable `subtitles.source`.
New translations use `"translated"`. Historical rows remain `NULL`; no historical
provenance is inferred. No Components or SaaS change is required for this feature.
