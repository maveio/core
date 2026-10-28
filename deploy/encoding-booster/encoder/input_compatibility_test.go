package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Exercise demuxer allowlists and actual encoded dimensions, including sources
// smaller than the ordinary video profiles. Fixtures contain synthetic media.
func TestSmallVideoAndWindowsMediaEncoding(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe is not installed")
	}
	for _, fixture := range []struct {
		name, operation, suffix string
		width                   int
		generate                []string
	}{
		{"small_h264", "video", ".mp4", 144, []string{"-f", "lavfi", "-i", "testsrc2=size=144x80:rate=5", "-c:v", "libx264"}},
		{"windows_video", "video", ".asf", 160, []string{"-f", "lavfi", "-i", "testsrc2=size=160x120:rate=5", "-c:v", "wmv2", "-f", "asf"}},
		{"windows_audio", "audio", ".asf", 0, []string{"-f", "lavfi", "-i", "sine=frequency=440", "-c:a", "wmav2", "-f", "asf"}},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			dir := t.TempDir()
			source := filepath.Join(dir, "source"+fixture.suffix)
			args := append([]string{"-v", "error"}, fixture.generate...)
			args = append(args, "-t", "1", "-threads", "1", source)
			if output, err := exec.Command(ffmpeg, args...).CombinedOutput(); err != nil {
				t.Fatalf("generate source: %v: %s", err, output)
			}
			request := encodeRequest{VideoCRF: 20, VideoMaxrate: "2M", VideoBufsize: "4M", Preset: "faster", KeyframeIntervalSeconds: 2, GOPFrames: 250, InputURL: "https://example.com/source", Operation: fixture.operation, Width: fixture.width}
			if fixture.operation == "audio" {
				request.VideoCRF = 0
				request.VideoMaxrate = ""
				request.VideoBufsize = ""
			}
			if err := request.validate(); err != nil {
				t.Fatal(err)
			}
			request.InputURL = source
			command := exec.Command(ffmpeg, ffmpegArgs(request, "cpu")...)
			var encoded, diagnostic bytes.Buffer
			command.Stdout, command.Stderr = &encoded, &diagnostic
			if err := command.Run(); err != nil {
				t.Fatalf("encode: %v: %s", err, diagnostic.String())
			}
			path := filepath.Join(dir, "encoded.media")
			if err := os.WriteFile(path, encoded.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			output, err := exec.Command(ffprobe, "-v", "error", "-show_entries", "stream=codec_type,width,height", "-of", "json", path).Output()
			if err != nil {
				t.Fatal(err)
			}
			var probe struct {
				Streams []struct {
					CodecType string `json:"codec_type"`
					Width     int    `json:"width"`
					Height    int    `json:"height"`
				} `json:"streams"`
			}
			if err := json.Unmarshal(output, &probe); err != nil || len(probe.Streams) != 1 {
				t.Fatalf("unexpected probe: %s (%v)", output, err)
			}
			stream := probe.Streams[0]
			if stream.CodecType != fixture.operation {
				t.Fatalf("wrong media stream: %+v", stream)
			}
			if fixture.width > 0 && (stream.Width > fixture.width || stream.Width%2 != 0 || stream.Height%2 != 0) {
				t.Fatalf("source was upscaled or produced odd dimensions: %+v", stream)
			}
			if fixture.operation == "video" {
				playlist := filepath.Join(dir, "playlist.m3u8")
				if output, err := exec.Command(ffmpeg, hlsArgs(path, dir)...).CombinedOutput(); err != nil {
					t.Fatalf("package capped CRF output: %v: %s", err, output)
				}
				var hashes []string
				for _, input := range []string{path, playlist} {
					output, err := exec.Command(ffmpeg, "-v", "error", "-i", input, "-map", "0:v:0", "-c", "copy", "-f", "hash", "-hash", "sha256", "-").CombinedOutput()
					if err != nil {
						t.Fatalf("hash packaged video: %v: %s", err, output)
					}
					hashes = append(hashes, strings.TrimSpace(string(output)))
				}
				if hashes[0] != hashes[1] {
					t.Fatalf("HLS changed compressed video packets: %v", hashes)
				}
			}
		})
	}
}
