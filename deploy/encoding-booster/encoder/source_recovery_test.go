package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestVideoSourceRecoveryProducesCompleteRenditions(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	ffprobe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Skip("ffprobe is not installed")
	}
	input := filepath.Join(t.TempDir(), "input.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10", "-t", "4", "-c:v", "libx264", "-threads", "1", "-movflags", "+faststart", input).CombinedOutput(); err != nil {
		t.Fatalf("source fixture: %v: %s", err, output)
	}
	data, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, codec := range []string{"h264", "hevc", "av1"} {
		for _, failure := range []string{"http502", "truncated"} {
			t.Run(codec+"/"+failure, func(t *testing.T) {
				var reads atomic.Int32
				source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if reads.Add(1) == 1 {
						if failure == "http502" {
							w.WriteHeader(502)
							return
						}
						w.Header().Set("Accept-Ranges", "bytes")
						w.Header().Set("Content-Length", strconv.Itoa(len(data)))
						w.Write(data[:len(data)/2])
						return
					}
					http.ServeContent(w, r, "input.mp4", time.Time{}, bytes.NewReader(data))
				}))
				defer source.Close()
				outputPath := filepath.Join(t.TempDir(), "rendition.mp4")
				audio := false
				request := encodeRequest{InputURL: source.URL, Operation: "video", Codec: codec, Width: 160, Preset: "ultrafast", IncludeAudio: &audio}
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				output, err := exec.CommandContext(ctx, ffmpeg, ffmpegArgsForOutput(request, "cpu", outputPath)...).CombinedOutput()
				if err != nil {
					t.Fatalf("encode did not recover: %v: %s", err, output)
				}
				frames, err := exec.Command(ffprobe, "-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", outputPath).CombinedOutput()
				if err != nil || strings.TrimSpace(string(frames)) != "40" || reads.Load() < 2 {
					t.Fatalf("rendition is incomplete: frames=%q reads=%d error=%v", frames, reads.Load(), err)
				}
			})
		}
	}
}
