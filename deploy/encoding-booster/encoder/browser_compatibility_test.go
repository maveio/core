package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestH264BrowserPixelFormats(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe is not installed")
	}
	probe := func(t *testing.T, path string) (string, string) {
		t.Helper()
		body, err := exec.Command(ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,pix_fmt", "-of", "json", path).Output()
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Streams []struct {
				Codec       string `json:"codec_name"`
				PixelFormat string `json:"pix_fmt"`
			} `json:"streams"`
		}
		if err := json.Unmarshal(body, &result); err != nil || len(result.Streams) != 1 {
			t.Fatalf("unexpected probe: %s (%v)", body, err)
		}
		return result.Streams[0].Codec, result.Streams[0].PixelFormat
	}
	for _, format := range []string{"yuv420p10le", "yuv422p10le", "yuv444p10le", "yuv444p"} {
		t.Run(format, func(t *testing.T) {
			dir := t.TempDir()
			source := filepath.Join(dir, "source.mp4")
			if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12", "-t", "1", "-vf", "format="+format, "-c:v", "libx264", "-threads", "1", "-pix_fmt", format, source).CombinedOutput(); err != nil {
				t.Fatalf("generate %s source: %v: %s", format, err, output)
			}
			if _, actual := probe(t, source); actual != format {
				t.Fatalf("fixture must retain %s, got %s", format, actual)
			}
			request := encodeRequest{InputURL: "https://example.test/source.mp4", Operation: "video", Codec: "h264", Width: 160, VideoCRF: 20, Preset: "faster"}
			if err := request.validate(); err != nil {
				t.Fatal(err)
			}
			request.InputURL = source
			command := exec.Command(ffmpeg, ffmpegArgs(request, "cpu")...)
			var encoded, diagnostics bytes.Buffer
			command.Stdout, command.Stderr = &encoded, &diagnostics
			if err := command.Run(); err != nil {
				t.Fatalf("encode: %v: %s", err, diagnostics.String())
			}
			output := filepath.Join(dir, "output.mp4")
			if err := os.WriteFile(output, encoded.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			if out, err := exec.Command(ffmpeg, hlsArgs(output, dir)...).CombinedOutput(); err != nil {
				t.Fatalf("package HLS: %v: %s", err, out)
			}
			for _, path := range []string{output, filepath.Join(dir, "playlist.m3u8")} {
				codec, pixels := probe(t, path)
				if codec != "h264" || pixels != "yuv420p" {
					t.Fatalf("%s is not browser H.264: codec=%s pix_fmt=%s", path, codec, pixels)
				}
			}
		})
	}
}
