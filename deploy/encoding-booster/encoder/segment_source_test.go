package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image/jpeg"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func segmentTestSourceClient(t *testing.T, client *http.Client) {
	t.Helper()
	previous := performSourceRequest
	performSourceRequest = client.Do
	t.Cleanup(func() { performSourceRequest = previous })
}

func TestSegmentDownloadRetriesWithoutKeepingPartialBytes(t *testing.T) {
	var attempts atomic.Int32
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "" || r.Header.Get("Referer") != "https://example.com/private" {
			t.Error("expected one full, authorized source read")
		}
		if user, password, ok := r.BasicAuth(); !ok || user != "user" || password != "password" {
			t.Error("source credentials were not forwarded")
		}
		switch attempts.Add(1) {
		case 1:
			w.WriteHeader(http.StatusServiceUnavailable)
		case 2:
			w.Header().Set("Content-Length", "100")
			_, _ = w.Write([]byte("truncated"))
		default:
			_, _ = w.Write([]byte("complete"))
		}
	}))
	defer source.Close()
	segmentTestSourceClient(t, source.Client())
	path := filepath.Join(t.TempDir(), "source.mp4")
	err := downloadSegmentSource(context.Background(), encodeRequest{
		InputURL: source.URL, InputReferer: "https://example.com/private", InputBasicAuth: "user:password",
	}, path, 1024, 0)
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil || string(body) != "complete" || attempts.Load() != 3 {
		t.Fatalf("expected clean third download, got %q, attempts=%d, err=%v", body, attempts.Load(), err)
	}
}

func TestSegmentDownloadRejectsBadSourcesAndCleansUp(t *testing.T) {
	for _, test := range []struct {
		name     string
		status   int
		body     string
		chunked  bool
		attempts int32
		message  string
	}{
		{"forbidden", 403, "secret error body", false, 1, "HTTP 403"},
		{"missing", 404, "", false, 1, "HTTP 404"},
		{"partial response", 206, "abc", false, 1, "HTTP 206"},
		{"unavailable", 502, "secret error body", false, 3, "HTTP 502"},
		{"empty", 200, "", false, 3, "empty"},
		{"oversized", 200, "too much data", false, 1, "download limit"},
		{"oversized chunked", 200, "too much data", true, 1, "download limit"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var attempts atomic.Int32
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				attempts.Add(1)
				w.WriteHeader(test.status)
				if test.chunked {
					w.(http.Flusher).Flush()
				}
				_, _ = w.Write([]byte(test.body))
			}))
			defer source.Close()
			segmentTestSourceClient(t, source.Client())
			path := filepath.Join(t.TempDir(), "source.mp4")
			err := downloadSegmentSource(context.Background(), encodeRequest{InputURL: source.URL + "?signature=secret"}, path, 8, 0)
			if err == nil || !strings.Contains(err.Error(), test.message) || strings.Contains(err.Error(), "secret") {
				t.Fatalf("expected sanitized %q error, got %v", test.message, err)
			}
			if attempts.Load() != test.attempts {
				t.Fatalf("attempts=%d", attempts.Load())
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatal("partial file remains")
			}
		})
	}
}

func TestSegmentPreparationCancelsBlockedDownloadAndCleansUp(t *testing.T) {
	scratch := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", scratch)
	started := make(chan struct{})
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "100")
		w.(http.Flusher).Flush()
		close(started)
		<-r.Context().Done()
	}))
	defer source.Close()
	segmentTestSourceClient(t, source.Client())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, cleanup, err := prepareSegmentSource(ctx, httptest.NewRecorder(), encodeRequest{InputURL: source.URL})
		cleanup()
		done <- err
	}()
	<-started
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("canceled download succeeded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("canceled download did not stop")
	}
	entries, _ := os.ReadDir(scratch)
	if len(entries) != 0 {
		t.Fatal("canceled source left scratch files")
	}
}

func TestSegmentPreparationKeepsResponseAliveDuringSlowDownload(t *testing.T) {
	scratch := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", scratch)
	release := make(chan struct{})
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "8")
		w.(http.Flusher).Flush()
		select {
		case <-release:
			_, _ = io.WriteString(w, "complete")
		case <-r.Context().Done():
		}
	}))
	defer source.Close()
	segmentTestSourceClient(t, source.Client())
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	writer := newSynchronizedResponseRecorder()
	done := make(chan error, 1)
	go func() {
		_, cleanup, err := prepareSegmentSource(ctx, writer, encodeRequest{InputURL: source.URL})
		cleanup()
		done <- err
	}()
	for !strings.Contains(writer.bodyString(), `"status":"preparing"`) {
		select {
		case <-writer.flushes:
		case <-ctx.Done():
			t.Fatal("no preparation heartbeat during download")
		}
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(scratch)
	if len(entries) != 0 {
		t.Fatal("source cleanup left scratch files")
	}
}

func TestSegmentsRejectInvalidDownloadedVideoAndCleanUp(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg is not installed")
	}
	scratch := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", scratch)
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "not a video")
	}))
	defer source.Close()
	segmentTestSourceClient(t, source.Client())
	writer := httptest.NewRecorder()
	encodeSegments(writer, context.Background(), encodeRequest{
		InputURL: source.URL, Operation: "segments", FrameCodec: "jpg", Count: 6, DurationSeconds: 6,
		OutputUploads: []assetUpload{{Name: "thumbnail_0.jpg"}},
	}, "cpu")
	if !strings.Contains(writer.Body.String(), `"status":"failed"`) || strings.Contains(writer.Body.String(), `"status":"completed"`) {
		t.Fatalf("invalid input must fail the entire set: %s", writer.Body.String())
	}
	entries, _ := os.ReadDir(scratch)
	if len(entries) != 0 {
		t.Fatal("failed encode left scratch files")
	}
}

func TestSegmentsUseOneCompleteDownloadForAllSixFrames(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	scratch := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", scratch)
	input := filepath.Join(t.TempDir(), "input.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10",
		"-t", "6", "-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", input).CombinedOutput(); err != nil {
		t.Fatalf("generate video: %v: %s", err, output)
	}
	data, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	var reads atomic.Int32
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		// Reproduce a source where remote seeking fails while a full GET works.
		if r.Header.Get("Range") != "" {
			w.WriteHeader(502)
			return
		}
		_, _ = w.Write(data)
	}))
	defer source.Close()
	segmentTestSourceClient(t, source.Client())
	var mu sync.Mutex
	frames := map[string][]byte{}
	completed := map[string]bool{}
	upload := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.Method {
		case http.MethodPut:
			frames[r.URL.Path], _ = io.ReadAll(r.Body)
			w.Header().Set("ETag", `"test-etag"`)
		case http.MethodPost:
			completed[r.URL.Path] = true
			_, _ = io.WriteString(w, "<CompleteMultipartUploadResult/>")
		default:
			t.Errorf("unexpected upload method %s", r.Method)
			w.WriteHeader(400)
		}
	}))
	defer upload.Close()
	request := encodeRequest{InputURL: source.URL, Operation: "segments", FrameCodec: "jpg", Count: 6, DurationSeconds: 6}
	for i := 0; i < 6; i++ {
		name := fmt.Sprintf("thumbnail_%d.jpg", i)
		request.OutputUploads = append(request.OutputUploads, assetUpload{Name: name, OutputUpload: multipartUpload{
			PartSizeBytes: 5 * 1024 * 1024, PartURLs: []string{upload.URL + "/" + name},
			CompleteURL: upload.URL + "/complete/" + name, AbortURL: upload.URL + "/abort/" + name,
		}})
	}
	writer := httptest.NewRecorder()
	encodeSegments(writer, context.Background(), request, "cpu")
	decoder := json.NewDecoder(strings.NewReader(writer.Body.String()))
	var last uploadEvent
	for decoder.More() {
		if err := decoder.Decode(&last); err != nil {
			t.Fatal(err)
		}
	}
	if last.Status != "completed" {
		t.Fatalf("segments failed: %s", writer.Body.String())
	}
	if reads.Load() != 1 {
		t.Fatalf("expected one source download, got %d", reads.Load())
	}
	mu.Lock()
	defer mu.Unlock()
	if len(frames) != 6 || len(completed) != 6 {
		t.Fatalf("expected six complete uploads, got %d/%d", len(frames), len(completed))
	}
	for name, body := range frames {
		if _, err := jpeg.Decode(bytes.NewReader(body)); err != nil {
			t.Fatalf("invalid thumbnail %s: %v", name, err)
		}
	}
	entries, _ := os.ReadDir(scratch)
	if len(entries) != 0 {
		t.Fatal("completed segments left scratch files")
	}
}

func TestStoryboardDownloadsCompleteSourceBeforeEncoding(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	input := filepath.Join(t.TempDir(), "input.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10",
		"-t", "6", "-c:v", "libx264", "-threads", "1", input).CombinedOutput(); err != nil {
		t.Fatalf("generate source: %v: %s", err, output)
	}
	data, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, invalid := range []bool{false, true} {
		t.Run(fmt.Sprintf("invalid_%v", invalid), func(t *testing.T) {
			scratch := t.TempDir()
			t.Setenv("BUNDLE_TEMP_DIR", scratch)
			var reads, ranged atomic.Int32
			source := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				reads.Add(1)
				if r.Header.Get("Range") != "" {
					ranged.Add(1)
					w.WriteHeader(http.StatusBadGateway)
					return
				}
				if invalid {
					_, _ = io.WriteString(w, "not a video")
				} else {
					_, _ = w.Write(data)
				}
			}))
			defer source.Close()
			segmentTestSourceClient(t, source.Client())
			var uploaded []byte
			var completed atomic.Bool
			storage := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.Method {
				case http.MethodPut:
					uploaded, _ = io.ReadAll(r.Body)
					w.Header().Set("ETag", `"part-1"`)
				case http.MethodPost:
					completed.Store(true)
				}
				w.WriteHeader(http.StatusOK)
			}))
			defer storage.Close()
			previous := http.DefaultClient
			http.DefaultClient = storage.Client()
			defer func() { http.DefaultClient = previous }()
			payload, _ := json.Marshal(encodeRequest{
				InputURL: source.URL, Operation: "storyboard", FrameCodec: "jpg", Count: 6, DurationSeconds: 6,
				OutputUpload: &multipartUpload{PartSizeBytes: 5 * 1024 * 1024,
					PartURLs:    []string{storage.URL + "/object?partNumber=1&uploadId=test"},
					CompleteURL: storage.URL + "/object?uploadId=test", AbortURL: storage.URL + "/object?uploadId=test"},
			})
			writer := httptest.NewRecorder()
			encodeHandler(10*time.Second, "test", "cpu", "", nil, newActivityTracker())(
				writer, httptest.NewRequest(http.MethodPost, "/encode", bytes.NewReader(payload)))
			if reads.Load() != 1 || ranged.Load() != 0 {
				t.Fatalf("expected one full source download, got reads=%d ranges=%d", reads.Load(), ranged.Load())
			}
			if invalid {
				if completed.Load() || !strings.Contains(writer.Body.String(), `"status":"failed"`) {
					t.Fatalf("invalid video must fail: %s", writer.Body.String())
				}
			} else {
				if !completed.Load() || !strings.Contains(writer.Body.String(), `"status":"completed"`) {
					t.Fatalf("storyboard did not complete: %s", writer.Body.String())
				}
				config, err := jpeg.DecodeConfig(bytes.NewReader(uploaded))
				if err != nil || config.Width != 1920 || config.Height != 180 {
					t.Fatalf("expected six storyboard tiles, got %+v: %v", config, err)
				}
			}
			entries, _ := os.ReadDir(scratch)
			if len(entries) != 0 {
				t.Fatal("storyboard left temporary media")
			}
		})
	}
}
