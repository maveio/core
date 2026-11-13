# Audio description

Audio description makes a video followable for blind and low-vision viewers: a
voice describes what happens on screen. A space opts in under **Settings →
Features → Audio description**. From then on, every new upload and reprocessing
run of a video of at most 10 minutes gets one description in its detected
spoken language (English when no language is known):

- `audio_description_<lang>.mp3`: a full mix of the video's own audio with the
  spoken descriptions. It is also an HLS alternate audio rendition, so players
  can switch to it.
- `descriptions_<lang>.vtt`: a WebVTT with `Kind: descriptions`, containing exactly
  the spoken descriptions, timed to when they are spoken.

Existing videos only get audio descriptions when they are processed again.

The flow input can set `audio_description.fallback_language` (default `en`).
A `fallback_language` step parameter overrides that default. These values are
used only when the original language is unknown; hosts can snapshot a space's
preferred fallback in the flow input without coupling the pipeline to space settings.

## How descriptions are planned and placed

Hosts may configure an optional `MaveCore.AudioDescription.Backend` to provide
another narration route and writer. Provider selection belongs in the run input
so retries remain consistent. The shared fitting, mixing and publication steps
are independent of that route; without a backend the pipeline below is used.

`NarrationPolicy` supplies the shared editorial instructions. Closing calls to
action retain their indispensable literal destination or instruction, without
requiring decorative framing or an already-spoken topic to be repeated. Visible
text checks ignore sentence punctuation while retaining URL paths and numeric
punctuation, so adding a comma does not invalidate an otherwise complete cue.

- **Visual observations first.** Scaleway records the setting, people and objects,
  actions, readable text, changes and uncertainties for every sampled frame. The
  vision request includes nearby timed speech as context, without a narration word limit. Samples cover
  at least two positions in shots lasting one second or longer, and approximately
  every two seconds in longer shots. Observations retain server-owned frame IDs
  and timestamps; partial or fabricated frame coverage is rejected. Text roles and
  prominence distinguish independent messages from subtitles and incidental interface
  details. Signs on physical objects are distinguished from title cards, and
  printed depictions from real objects. A cut requires re-establishing spatial
  relationships rather than carrying the preceding scene into the new frame.
  Spoken context never counts as proof of unseen visual facts.
- **Whole-video writing.** Mistral Large 4 receives the complete observations,
  shot boundaries, timed transcript, measured speech intervals and available
  pauses. It writes the original-language script, referencing observation IDs.
  Names become available only after their introduction. Repeated angles are not
  new events, while successive meaningful actions and locations remain distinct.
  The writer must not invent missing transitions or complete uncertain text. It
  omits illustrative footage and repeated settings when the explanation already
  supplies their meaning. Readable counters and background notes are not essential
  merely because they are unspoken. Consecutive cues retain subject continuity
  and avoid repeating one activity through its incidental signs or labels.
  Primary closing messages receive separate,
  concise cues rather than being combined with subsequent logos or addresses.
  Each distinct meaningful event gets its own short cue, evidence references and
  observed `event_start`/`event_end`. Successive steps stay separate even within
  one camera shot; multiple angles of one continuing action may share a cue.
  The scheduler intersects event boundaries with measured shot evidence, so later
  actions cannot borrow an earlier event's pause. Independent cues are not merged
  merely because their proposed speaking times coincide. Legacy script responses
  without event boundaries retain their evidence-based windows.
  Before scheduling, every explicit event window must contain a timestamp from
  its cited observations. Conflicting references or times receive a targeted
  correction using the saved observations near that event, in batches of at
  most six cues. Valid cues are preserved. Corrected references and times are
  checked again; unsupported events are recorded as `unsupported_visual_alignment`
  rather than disappearing as if there were no speaking time. This temporal
  validation does not prove that every visual claim is correct.
  The configured writer provider is independent of vision and speech synthesis.
- **Traceable intermediate results.** Private `observations.json` is persisted
  before writing begins, so a writing failure does not discard the image analysis.
  Unknown evidence IDs and invalid cue times are rejected before scheduling.
  On retry, saved observations are reused only when their frame IDs, timestamps,
  scenes and recorded language match the current input. Existing observations
  without a recorded language remain supported. Incomplete or mismatched caches
  are regenerated; storage outages remain errors rather than triggering a new
  paid vision request.
  Writing receives the timed transcript once instead of repeating its passages
  in every frame. Pause IDs and provisional per-cue word counts are computed
  locally, so they are not requested from the writer. Script writing uses low
  reasoning effort and a 24,000-token output allowance. Only a truncated answer
  gets one retry with 32,000 tokens, using the same observations; an incomplete
  script is never accepted. Private `script-request-<attempt>.json` files record
  model, reasoning effort, elapsed time, finish reason and provider token usage
  when available, without model text or reasoning content. Progress distinguishes
  image analysis, reuse, script writing and a truncated-script retry.
  Targeted alignment requests have separate private request metrics and an
  `alignment-report.json` result. A repair-only retry can set
  `audio_description.reuse_script` to true. Set
  `audio_description.reuse_observations_only` to true to fail if matching saved
  observations are unavailable, without making a new vision request.
- **Content and duration budgets.** Short clips get a compact script. Interviews,
  tutorials, montages, music and stories receive different editorial guidance.
  Music and dialogue-heavy interviews have lower narration budgets. Essential
  text and actions take priority over optional visual detail. At equal priority,
  actions reserve time before routine text or background settings; essential
  text keeps precedence. The model must not
  invent unreadable text or identities. Initial speech estimates use 2.5 words/s;
  these are planning limits, not guarantees of synthesized duration.
- **Protected speech and ending.** Narration begins no earlier than 500 ms into
  the video, leaving a short natural lead-in. Later events keep their own timing;
  the delay is not added to each cue. New cues reserve non-overlapping windows in
  measured speech pauses, within the relevant scene and before the video end
  minus 300 ms. Event windows also prevent a cue from displacing the next equally
  important action, even when cut detection groups both into one scene. A cue's
  visual availability is derived from the shots containing its cited observations,
  rather than treating the model's proposed speaking time as a hard lower bound.
  Essential visible text gets first access to pause time and may wait for a later pause
  while it remains on screen. Narration does
  not automatically cover continuous dialogue for routine details. Useful
  priority-2 cues may use a reserved extension starting in their speech pause,
  overlapping at most 800 ms and 25% of their duration with original speech.
  Extensions stay within the event and cannot displace another reserved cue.
  Missing essential cues
  set `review_required` in the step output. A speech pause does not prove that
  music or sound effects there are unimportant; these still need listening review.
- **Voice delivery.** Descriptions use a warm delivery at the voice's natural
  rate. A fast pace is requested only by the measured fitting fallback. Dutch
  URLs are expanded to Dutch letter names and separators for synthesis only;
  the VTT retains the original spelling.
- **Local speech estimates.** Before synthesis, a local heuristic estimates duration
  from vowel groups, word count, numeric groups, abbreviations, punctuation and
  the existing spoken URL expansion. Clearly oversized text is rewritten before
  calling the speech provider; borderline estimates proceed to synthesis. These
  coefficients are not calibrated voice measurements and do not establish timing
  accuracy for every language. A failed content-preserving preflight rewrite falls
  back to measuring the original text rather than dropping it on an estimate.
  Preflight and measured repair share the two-rewrite allowance per window.
- **Measured speech and repair.** After synthesis, the complete clip must fit its
  reserved window. Oversized text is rewritten with a measured word budget
  and synthesized again. For text cues, the required literal message is measured
  on its own before rewriting framing or decorative detail. Extra numeric
  instructions may not disappear in that fallback. The rewriter receives the
  original event, required text, measured speaking time and available seconds.
  Revisions use the same configured writer as script generation (Mistral by
  default), rather than the vision provider. Short Mistral revisions use low
  reasoning effort, as does full script generation. Truncated or
  malformed revision responses never cancel other descriptions. Preflight falls
  back to measuring the original; an unusable measured revision is recorded per
  cue and sets `review_required`. Transport and service errors remain retryable.
  If a rewritten phrase still overruns, one further rewrite uses its newly measured
  speaking rate to choose a smaller target. This keeps the existing two-attempt
  rewrite limit. Planning word counts remain estimates: complete audio that fits
  naturally is retained even when the initial word estimate was conservative.
  Rewrites may also exceed the estimated word target to retain natural grammar,
  but cannot grow beyond the input's word count or exceed the actual time window.
  Written words per second do not reject a naturally synthesized clip that fits;
  they vary by language and are not a reliable measure of delivery speed. Useful
  cues try their reserved extension before rewriting the original sentence.
  An only slightly oversized rewrite can try a faster
  delivery, capped at a measured 15% speed increase. If it still
  does not fit, it is omitted and recorded for review. Required on-screen text
  and numeric values may not silently disappear during rewriting.
- **Matching text and sound.** The final VTT uses the actual accepted wording and
  spoken timing. No audio is cut to fit. Intermediate plans and omitted cues
  remain private; outputs include category, adjustment and omission counts,
  uncovered essential text, measured speech overlap and room left at the end.
  Text already spoken in the source transcript counts as covered.
  The original audio, including background music during speech pauses, fades
  down to 20% for every spoken description. It fades down during the preceding
  300 ms and returns during the following 300 ms. Overlapping fades use the
  strongest attenuation rather than multiplying gains. Speech-overlap metrics
  still count only descriptions that actually overlap original dialogue.
- **Readable stills.** The image model gets labelled 720p stills, approximately
  one per 3 s per shot, with explicit beginning/end samples, in batches of 12.
  Fine text between sampled frames can still be missed. This is automatic draft
  generation; human listening and visual checks remain necessary for quality.

These choices follow the emphasis on relevance, timing and protected dialogue in
[the DCMP Description Key](https://dcmp.org/learn/descriptionkey) and
[Netflix's audio description guide](https://partnerhelp.netflixstudios.com/hc/en-us/articles/215510667-Audio-Description-Style-Guide-v2-5).

## Flow steps

The publishing presets (`publish_default`, `publish_local`, `publish_remote`,
`publish_remote_local`) contain these optional background steps. Each one skips
itself (`status: "skipped"`, `reason: "not_requested"`) unless the run input has
`audio_description`, so disabled spaces do not call the AI providers. Nothing in the publish
path waits for them; when a mix step finishes, Core stores the result, rebuilds the
HLS master playlist and republishes `manifest.json`.

| Step | Type | Runs on | Does |
| --- | --- | --- | --- |
| `detect_scenes` | `media.detect_scenes` | FLAME (media pool) | Cuts, scenes and stills in one decode of the canonical source |
| `describe_video` | `ai.describe_video` | inline | Rich visual observations, full-video writing and reserved time windows |
| `speak_descriptions_original` | `ai.speak_descriptions` | inline | Synthesis, duration checks and bounded repair; existing clips are reused on retry |
| `mix_audio_description_original` | `media.mix_audio_description` | FLAME (media pool) | Timeline, ducked mix, VTT and the HLS audio rendition |

Run input:

```json
{"audio_description": {"languages": ["original"], "fallback_language": "en"}}
```

Uploads and the public `input_url` API add this when the space has the feature on
and the host allows it at that moment (see below). Existing runs keep their
original versioned flow definition; newly started runs use the single-language preset.
Videos longer than `MAVE_AUDIO_DESCRIPTION_MAX_SECONDS` (default `600`) are
skipped with `reason: "video_too_long"`, `video_duration_seconds` and
`max_duration_seconds`; videos without a video stream with `no_video`.

Transient provider and storage errors (timeouts, 408/429/5xx) are retried with the
flow engine's retry budget. Other failures make the step `unavailable`; they never
block publication. Working objects (stills, cues, speech clips) are private and
live under `<embed>/vN/audio_description/`.

The video settings panel shows dimmed pending rows for audio tracks, descriptions
and subtitles requested by the current run. They have a processing indicator and
no file actions until the output is available; skipped, cancelled and failed work
is not presented as still generating.

## Outputs

Files sit next to the other media of the video version (`<embed>/vN/`):
`audio_description_<lang>.mp3`, `audio_description_<lang>_hls/playlist.m3u8` and
`descriptions_<lang>.vtt`. Generated rows are identified by video version and
generation language; uploaded tracks may share the same language.

The HLS master playlist lists each MP3 in the `audio` group:

```text
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Dutch (AD)",LANGUAGE="nl",DEFAULT=NO,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",URI="audio_description_nl_hls/playlist.m3u8"
```

`manifest.json` has a separate key, so players that don't know it are unaffected
(the existing `audio_tracks` and `subtitles` don't include audio descriptions):

```json
"audio_descriptions": [
  {
    "language": "nl",
    "label": "Dutch (AD)",
    "audio": {"path": "https://…/audio_description_nl.mp3", "hls_playlist": "audio_description_nl_hls/playlist.m3u8", "file_size": 123456},
    "vtt": {"path": "https://…/descriptions_nl.vtt", "file_size": 1234}
  }
]
```

The key is omitted when a video has none. The detailed video API payload has the
same `audio_descriptions` list. The dashboard video page lists the available
languages and HLS/MP3/VTT formats under **Audio descriptions** in Settings and
**Audio** in Info, where descriptions are marked `(AD)`.

The file menu on audio tracks, audio descriptions and subtitles provides file
downloads and replacement. Removing a track asks for confirmation.

Under **Settings → Audio descriptions**, tracks can be uploaded, renamed,
retagged with a language, replaced, or removed. Upload a complete MP3 mix with
both the original audio and spoken descriptions; the player switches tracks
rather than mixing them. Uploaded tracks can share a language. A manually
replaced track has no generated VTT, since the old text may not match the new
audio. The replacement menu also supports uploading or replacing the associated
VTT. The generated pipeline creates both files automatically. Background publication preserves manually edited and removed tracks.

## Who may use it

`MaveCore.UsageLimits.can_use_audio_description?/1` is an optional host callback.
Without a host policy every space may turn the feature on. A host can refuse with
`{:error, reason}` and provide `restriction_copy(:audio_description, reason)`;
the dashboard then shows the notice and keeps the toggle off. Turning the feature
off is allowed unless the host manages the setting. The check is repeated for
every new run, so a space that loses access stops getting audio descriptions
without changing its setting.

Hosts can also implement `can_manage_audio_description?/1`. Returning
`{:error, reason}` hides the setting and rejects changes through
`Spaces.update_space_features/2`, including attempts to disable it. This lets a
host manage access through its own authorized interface. Both callbacks default
to allowing access when no policy is configured.

Track labels are used verbatim in the player. The default description label is
`<language> (AD)`. Original audio uses `<language> (original)` when its language
is known, and `Original` otherwise. Custom labels are preserved.

## Providers and configuration

The default providers are Scaleway Generative APIs and Mistral. Video stills,
speech timings and description text are sent to the configured providers.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCALEWAY_API_KEY` | — | Scaleway IAM application with only `GenerativeApisModelAccess` |
| `MISTRAL_API_KEY` | — | Already used for transcription; also used for text-to-speech |
| `MAVE_AUDIO_DESCRIPTION_ENDPOINT` | `https://api.scaleway.ai/v1/chat/completions` | Override with `https://api.scaleway.ai/<project-id>/v1/chat/completions` for a project-scoped key |
| `MAVE_AUDIO_DESCRIPTION_MODEL` | `gemma-4-26b-a4b-it` | Describe and translate model |
| `MAVE_AUDIO_DESCRIPTION_REASONING_EFFORT` | `none` | Scaleway `reasoning_effort`; with reasoning, Gemma runs out of tokens |
| `MAVE_AUDIO_DESCRIPTION_WRITER_MODEL` | `mistral-large-4-0` | Text-only writer; medium reasoning effort |
| `MAVE_AUDIO_DESCRIPTION_TTS_MODEL` | `voxtral-mini-tts-3-0` | Mistral text-to-speech model |
| `MAVE_AUDIO_DESCRIPTION_VOICES` | `en:gb_jane_neutral,nl:voice_3145` | Voice per language |
| `MAVE_AUDIO_DESCRIPTION_VOICE` | `gb_jane_neutral` | Voice for languages without one |
| `MAVE_AUDIO_DESCRIPTION_MAX_SECONDS` | `600` | Longest video that gets descriptions |

The default voices are Jane (English) and Lotte (Dutch), both presets. Lotte
requires Voxtral 3; the older `voxtral-mini-tts-2603` model rejects this voice.
When overriding the model or voices, verify that they are compatible. See
[Mistral's voice catalog](https://docs.mistral.ai/studio/audio/text-to-speech/voices).

Scope the Scaleway application's `GenerativeApisModelAccess` policy to the
intended project and use that project's endpoint above. Setting a key's default
project alone does not restrict its permissions. Prefer expiring credentials
and keep them in the runtime environment, outside version control.

Tests replace the providers through application config:

```elixir
config :mave_core, :audio_description,
  chat_provider: MyChatStub,
  writer_provider: MyWriterStub,     # chat_json(system, content, opts)
  speech_provider: MySpeechStub, # speak(text, language) -> {:ok, wav_bytes}
  max_seconds: 600
```
