package main

import (
	"bufio"
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestHLSProcessesFragmentedMP4BeforeReadingTheWholeSource(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	input := filepath.Join(t.TempDir(), "input.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
		"testsrc2=size=160x90:rate=10", "-t", "90", "-c:v", "libx264", "-preset", "ultrafast",
		"-threads", "1", "-g", "60", "-movflags", "frag_keyframe+empty_moov+default_base_moof", input).CombinedOutput(); err != nil {
		t.Fatalf("generate fragmented fixture: %v: %s", err, output)
	}
	data, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	processed := make(chan struct{})
	var release sync.Once
	defer release.Do(func() { close(processed) })
	var reads atomic.Int32
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		if r.Header.Get("Range") == "bytes=0-" {
			w.Header().Set("Content-Range", "bytes 0-"+strconv.Itoa(len(data)-1)+"/"+strconv.Itoa(len(data)))
			w.WriteHeader(http.StatusPartialContent)
		} else if r.Header.Get("Range") != "" {
			t.Error("HLS unexpectedly sought back through the source")
			return
		}
		_, _ = w.Write(data[:len(data)/2])
		w.(http.Flusher).Flush()
		select {
		case <-processed:
			_, _ = w.Write(data[len(data)/2:])
		case <-r.Context().Done():
		}
	}))
	defer source.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dir := t.TempDir()
	args := append([]string{"-progress", "pipe:1", "-stats_period", "0.01"}, hlsArgs(source.URL, dir)...)
	command := exec.CommandContext(ctx, ffmpeg, args...)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		if value, ok := strings.CutPrefix(scanner.Text(), "out_time_us="); ok {
			micros, _ := strconv.ParseInt(value, 10, 64)
			if micros >= 6_000_000 {
				release.Do(func() { close(processed) })
			}
		}
	}
	if err := command.Wait(); err != nil {
		t.Fatalf("HLS must process the first half before requesting the rest: %v: %s", err, &stderr)
	}
	if reads.Load() != 1 {
		t.Fatalf("expected a single source read, got %d", reads.Load())
	}
	playlist, err := os.ReadFile(filepath.Join(dir, "playlist.m3u8"))
	if err != nil || !strings.Contains(string(playlist), "#EXT-X-ENDLIST") {
		t.Fatalf("missing complete HLS playlist: %v", err)
	}
	var duration float64
	for _, line := range strings.Split(string(playlist), "\n") {
		if value, ok := strings.CutPrefix(line, "#EXTINF:"); ok {
			seconds, _ := strconv.ParseFloat(strings.TrimSuffix(value, ","), 64)
			duration += seconds
		}
	}
	if duration < 89.99 || duration > 90.01 {
		t.Fatalf("expected all 90 seconds in the playlist, got %f", duration)
	}
}
