# Encoding benchmarks

Core includes `mix perf.encoding` to compare encoder settings before they
change the production encoding profile. It encodes a set of clips with several
candidates and measures each encode against the current production renditions:

- **Visual quality**: SSIM and PSNR against a lossless reference, plus VMAF
  when the local FFmpeg build includes the `libvmaf` filter.
- **File size**: bytes and bitrate of the video stream.
- **Encoding time**: wall-clock time, speed relative to realtime, and CPU time.
- **Playback compatibility**: codec profile, pixel format, the longest stretch
  without a keyframe, and whether the result plays everywhere, needs an H.264
  fallback next to it, or is not safe to serve to browsers.

The task only needs `ffmpeg` and `ffprobe` on `PATH`. It does not start the
application and does not use a database or object storage.

## Run a benchmark

```sh
mix perf.encoding --tag baseline
```

This measures the built-in clips at the `hd` rendition size and writes
`results.json` and a self-contained `report.html` to
`tmp/encoding-benchmark/baseline/`. The terminal shows the same summary:
every candidate against the baseline, and the smallest encode per clip that
keeps the baseline's quality and playback reach.

The built-in clips come from FFmpeg's deterministic test sources, so everyone
measures the same pixels without sharing media. They stress different encoder
behavior (sharp graphics, constantly changing detail, grain over gradients,
mostly static slides) but they are not real footage. To measure a
representative set, point the task at a directory of videos:

```sh
mix perf.encoding --source ~/Videos/benchmark-set --size fhd --duration 10
```

Use media you are allowed to process locally. The results contain file names,
so check them before sharing a report.

| Option | Purpose |
| --- | --- |
| `--source DIR` | Measure the videos in `DIR` instead of the built-in clips |
| `--size hd` | Rendition size: `sd`, `hd`, `fhd`, `qhd` or `uhd` |
| `--duration 6` | Seconds measured per clip |
| `--candidates a,b` | Only measure these candidates |
| `--candidates-file FILE` | Add candidates from a JSON file |
| `--clips a,b` | Only measure these clips |
| `--baseline ID` | Candidate the others are compared with |
| `--tolerance 1.0` | Quality drop that counts as a regression |
| `--tag NAME` | Name of the run; defaults to a UTC timestamp |
| `--output DIR` | Where to write the results and the report |
| `--compare FILE` | Earlier `results.json` to compare this run with |
| `--keep-media` | Keep references and encodes to inspect them |
| `--list` | Print the available clips and candidates |
| `--report FILE` | Render the report again from a stored `results.json` |

## Candidates

`production-h264`, `production-hevc` and `production-av1` are built from
`MaveCore.Media.ProductionEncodingProfile` with the arguments the encoding
booster uses on CPU, so the baseline follows the production contract. The
remaining built-in candidates vary the H.264 ladder rendition: a higher CRF
under the same bitrate cap, and slower presets.

Add your own in a JSON file. A list of `crf` values expands into one candidate
per value, which gives a rate-quality curve for the per-video selection:

```json
[
  {"id": "h264-veryslow", "codec": "h264", "preset": "veryslow",
   "crf": [20, 22, 24], "maxrate": "4M", "bufsize": "8M"},
  {"id": "av1-fast", "codec": "av1", "preset": "fast", "crf": [30, 34]},
  {"id": "x265-aq", "codec": "hevc", "crf": 26, "params": "aq-mode=3"}
]
```

Supported keys are `id`, `codec` (`h264`, `hevc`, `av1`), `preset`, `crf`,
`bitrate`, `maxrate` with `bufsize`, `tune`, `params` (passed as
`-x264-params`, `-x265-params` or `-svtav1-params`), `gop_frames`,
`keyframe_interval_seconds` and `description`. Candidates whose encoder is
missing from the local FFmpeg build are skipped with a warning.

## Read the results

A candidate is compared with the baseline clip by clip. The summary shows the
total size change, the average quality change and the **worst clip**: a
candidate that is better on average can still make one kind of content visibly
worse. A clip counts as regressed when it loses more than the tolerance, by
default 2 VMAF points, or 1 dB of SSIM when VMAF is not available. Treat the
tolerance as a screening threshold and look at the encodes (`--keep-media`)
before changing a profile.

The per-video selection shows what choosing settings per clip would save. It
only considers encodes with the baseline's playback reach, so an AV1 encode is
never picked to replace the universal H.264 rendition.

## Track changes over time

Results are plain JSON, so a run can be kept and compared with a later one, for
example after an FFmpeg or encoder upgrade or a profile change:

```sh
mix perf.encoding --tag ffmpeg-7.1 \
  --compare tmp/encoding-benchmark/ffmpeg-6.1/results.json
```

The comparison lists what changed between the two environments and the size,
quality and time change of every measurement both runs share. Keep the clips,
size and duration identical between runs.

## Limitations

- Every clip is first converted to a lossless 8-bit 4:2:0 reference at the
  rendition size, and candidates encode that reference. The numbers isolate
  encoder settings; they exclude source decoding, scaling and HDR handling.
- Encoding time is a single wall-clock measurement on the machine running the
  task, with FFmpeg's default threading. Compare times only between runs on the
  same idle hardware.
- The built-in clips are bit-identical on every run, and most encodes are too.
  Multithreaded x264 rate control is not deterministic, so encodes that reach
  the bitrate cap can differ by a few percent between identical runs. Size and
  quality also depend on encoder versions and the number of CPU threads.
- Candidates run through local software encoders. Hardware encoders and the
  booster's chunked encoding are not measured.
- Playback compatibility is a static assessment of the stream properties, not
  a device test.
- SSIM and PSNR do not model perception the way VMAF does. Prefer an FFmpeg
  build with `libvmaf` when comparing codecs with each other.
