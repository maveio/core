# Audio description

Audio description makes a video followable for blind and low-vision viewers: a
voice describes what happens on screen. A space opts in under **Settings →
Features → Audio description**. From then on, every new upload and reprocessing
run of a video of at most 10 minutes gets, in English and Dutch:

- `audio_description_<lang>.mp3`: a full mix of the video's own audio with the
  spoken descriptions. It is also an HLS alternate audio rendition, so players
  can switch to it.
- `descriptions_<lang>.vtt`: a WebVTT with `Kind: descriptions`, containing exactly
  the spoken descriptions, timed to when they are spoken.

Existing videos only get audio descriptions when they are processed again.

## How descriptions are placed

- **English first.** The video is described in English from what is on screen.
  Every other language is a translation of that English text, never a separate
  description.
- **In the pauses, otherwise ducked.** Where speech is, is measured with
  speech-to-text (the `ai.transcribe_audio` segments, or a transcription made for
  this purpose), never guessed by the description model. A description that fits a
  pause near its moment (up to 1 s earlier or 2 s later) plays there and leaves the
  original audio untouched. When none fits, it plays at its moment and the original
  audio fades to 20% underneath it (0.3 s fades). Descriptions are not shortened to
  make room.
- **In sync with the picture.** Cuts are detected with FFmpeg `scdet` and grouped
  into scenes of at least 3 s, so a fast montage is still described. A description
  starts while its scene is on screen and at least half of it is spoken during the
  scene; a pause after the cut never counts as room for it. One that can no longer
  start in its scene, because earlier descriptions ran long, is left out.
- **Labelled stills.** The image model gets one 360p still per ~3 s per shot
  (at least one per cut), labelled `S<scene> at <time>`, in batches of 12, with the
  scenes, speech and numbered pauses (each with a word budget) as context.

## Flow steps

The publishing presets (`publish_default`, `publish_local`, `publish_remote`,
`publish_remote_local`) contain these optional background steps. Each one skips
itself (`status: "skipped"`, `reason: "not_requested"`) unless the run input has
`audio_description`, so other spaces pay nothing for them. Nothing in the publish
path waits for them; when a mix step finishes, Core stores the result, rebuilds the
HLS master playlist and republishes `manifest.json`.

| Step | Type | Runs on | Does |
| --- | --- | --- | --- |
| `detect_scenes` | `media.detect_scenes` | FLAME (media pool) | Cuts, scenes and stills in one decode of the canonical source |
| `describe_video` | `ai.describe_video` | inline | English cues |
| `translate_descriptions_nl` | `ai.translate_descriptions` | inline | Dutch cues, same timings |
| `speak_descriptions_<lang>` | `ai.speak_descriptions` | inline | Text-to-speech per cue; existing clips are reused on retry |
| `mix_audio_description_<lang>` | `media.mix_audio_description` | FLAME (media pool) | Timeline, ducked mix, VTT and the HLS audio rendition |

Run input:

```json
{"audio_description": {"languages": ["en", "nl"]}}
```

Uploads and the public `input_url` API add this when the space has the feature on
and the host allows it at that moment (see below). English is always included.
Videos longer than `MAVE_AUDIO_DESCRIPTION_MAX_SECONDS` (default `600`) are
skipped with `reason: "video_too_long"`, `video_duration_seconds` and
`max_duration_seconds`; videos without a video stream with `no_video`.

Transient provider and storage errors (timeouts, 408/429/5xx) are retried with the
flow engine's retry budget. Other failures make the step `unavailable`; they never
block publication. Working objects (stills, cues, speech clips) are private and
live under `<embed>/vN/audio_description/`.

## Outputs

Files sit next to the other media of the video version (`<embed>/vN/`):
`audio_description_<lang>.mp3`, `audio_description_<lang>_hls/playlist.m3u8` and
`descriptions_<lang>.vtt`. The `audio_descriptions` table holds one row per video
version and language.

The HLS master playlist lists each MP3 in the `audio` group:

```text
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Dutch (audio description)",LANGUAGE="nl",DEFAULT=NO,AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",CHANNELS="2",URI="audio_description_nl_hls/playlist.m3u8"
```

`manifest.json` has a separate key, so players that don't know it are unaffected
(the existing `audio_tracks` and `subtitles` don't include audio descriptions):

```json
"audio_descriptions": [
  {
    "language": "nl",
    "label": "Dutch (audio description)",
    "audio": {"path": "https://…/audio_description_nl.mp3", "hls_playlist": "audio_description_nl_hls/playlist.m3u8", "file_size": 123456},
    "vtt": {"path": "https://…/descriptions_nl.vtt", "file_size": 1234}
  }
]
```

The key is omitted when a video has none. The detailed video API payload has the
same `audio_descriptions` list, and the dashboard video page links the MP3 and VTT
files.

## Who may use it

`MaveCore.UsageLimits.can_use_audio_description?/1` is an optional host callback.
Without a host policy every space may turn the feature on. A host can refuse with
`{:error, reason}` and provide `restriction_copy(:audio_description, reason)`;
the dashboard then shows the notice and keeps the toggle off. Turning the feature
off is always allowed. The check is repeated for every new run, so a space that
loses access stops getting audio descriptions without changing its setting.

## Providers and configuration

Everything runs on EU providers: Scaleway Generative APIs (nl-ams) and Mistral.
Video stills, the speech timings and the description text are sent to them.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCALEWAY_API_KEY` | — | Scaleway IAM application with only `GenerativeApisModelAccess` |
| `MISTRAL_API_KEY` | — | Already used for transcription; also used for text-to-speech |
| `MAVE_AUDIO_DESCRIPTION_MODEL` | `gemma-4-26b-a4b-it` | Describe and translate model |
| `MAVE_AUDIO_DESCRIPTION_REASONING_EFFORT` | `none` | Scaleway `reasoning_effort`; with reasoning, Gemma runs out of tokens |
| `MAVE_AUDIO_DESCRIPTION_TTS_MODEL` | `voxtral-mini-tts-2603` | Mistral text-to-speech model |
| `MAVE_AUDIO_DESCRIPTION_VOICES` | `en:gb_jane_neutral,nl:nl_kore_neutral` | Voice per language |
| `MAVE_AUDIO_DESCRIPTION_VOICE` | `gb_jane_neutral` | Voice for languages without one |
| `MAVE_AUDIO_DESCRIPTION_MAX_SECONDS` | `600` | Longest video that gets descriptions |

Every language needs a voice in that language: Voxtral keeps the accent of its
voice prompt. Mistral has no Dutch preset, so `nl_kore_neutral` is a cloned voice
that must exist in the Mistral account of `MISTRAL_API_KEY`. Create voices only
from a speaker who consented or from a synthetic sample, never from customer
videos.

Tests replace the providers through application config:

```elixir
config :mave_core, :audio_description,
  chat_provider: MyChatStub,     # chat_json(system, content, opts)
  speech_provider: MySpeechStub, # speak(text, language) -> {:ok, wav_bytes}
  max_seconds: 600
```
