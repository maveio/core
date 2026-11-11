package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestIntermediateVideoChunkUploadsBeforeEncodingCompletes(t *testing.T) {
	testStreamingVideoUpload(t, 600, 0)
}

func TestFullLengthVideoUploadsBeforeEncodingCompletes(t *testing.T) {
	testStreamingVideoUpload(t, 0, 0)
}

func TestLongCappedVideoUploadsBeforeEncodingCompletes(t *testing.T) {
	testStreamingVideoUpload(t, 0, 3600)
}

func testStreamingVideoUpload(t *testing.T, duration float64, maxDuration int) {
	t.Helper()
	scratch := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", scratch)
	bin := t.TempDir()
	gate := filepath.Join(bin, "uploaded")
	if err := syscall.Mkfifo(gate, 0600); err != nil {
		t.Fatal(err)
	}
	quote := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
	// The encoder cannot finish until storage receives the first part. Staging
	// this output on disk would deadlock and fail the request's deadline.
	script := fmt.Sprintf(`#!/bin/sh
for arg do output="$arg"; done
[ "$output" = 'pipe:1' ] || exit 1
dd if=/dev/zero bs=1048576 count=5 2>/dev/null
read uploaded < %s
printf end
printf 'frame=50\nprogress=end\n' >&2
`, quote(gate))
	if err := os.WriteFile(filepath.Join(bin, "ffmpeg"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	var completed atomic.Bool
	var parts atomic.Int32
	storage := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut {
			_, _ = io.Copy(io.Discard, r.Body)
			if parts.Add(1) == 1 {
				if err := os.WriteFile(gate, []byte("uploaded\n"), 0600); err != nil {
					t.Error(err)
				}
			}
			w.Header().Set("ETag", `"part"`)
		} else if r.Method == http.MethodPost {
			completed.Store(true)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer storage.Close()
	previous := http.DefaultClient
	http.DefaultClient = storage.Client()
	defer func() { http.DefaultClient = previous }()
	request := encodeRequest{
		InputURL: "https://example.test/source.mp4", Operation: "video", Codec: "h264", Width: 320,
		StartSeconds: 0, DurationSeconds: duration,
		MaxDurationSeconds: maxDuration,
		OutputUpload: &multipartUpload{
			PartSizeBytes: 5 * 1024 * 1024,
			PartURLs:      []string{storage.URL + "/video?partNumber=1", storage.URL + "/video?partNumber=2"},
			CompleteURL:   storage.URL + "/video", AbortURL: storage.URL + "/video",
		},
	}
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	encodeHandler(5*time.Second, "test", "cpu", "", nil, newActivityTracker())(
		response, httptest.NewRequest(http.MethodPost, "/encode", bytes.NewReader(payload)))
	if !completed.Load() || parts.Load() != 2 || !strings.Contains(response.Body.String(), `"status":"completed"`) {
		t.Fatalf("chunk must stream before encoding completes: %s", response.Body.String())
	}
	entries, err := os.ReadDir(scratch)
	if err != nil || len(entries) != 0 {
		t.Fatalf("intermediate chunks must not stage output on scratch: %v %v", entries, err)
	}
}

func assertFaststartMP4(t *testing.T, data []byte) {
	t.Helper()
	moov, mdat := -1, -1
	for offset := 0; offset+8 <= len(data); {
		size := int(binary.BigEndian.Uint32(data[offset:]))
		kind := string(data[offset+4 : offset+8])
		if size == 1 && offset+16 <= len(data) {
			size = int(binary.BigEndian.Uint64(data[offset+8:]))
		}
		if size < 8 || size > len(data)-offset {
			t.Fatalf("invalid %s box at %d", kind, offset)
		}
		switch kind {
		case "moov":
			moov = offset
		case "mdat":
			mdat = offset
		case "moof":
			t.Fatal("published MP4 contains movie fragments")
		}
		offset += size
	}
	if moov < 0 || mdat < 0 || moov >= mdat {
		t.Fatalf("sample index must precede media: moov=%d mdat=%d", moov, mdat)
	}
}

func TestDirectVideoUploadsPublishFaststartMP4(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	encoders, err := exec.Command(ffmpeg, "-hide_banner", "-encoders").CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(t.TempDir(), "source.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:v", "libx264", "-threads", "1", "-c:a", "aac", source).CombinedOutput(); err != nil {
		t.Fatalf("generate source: %v: %s", err, output)
	}
	for _, codec := range []struct{ name, encoder string }{{"h264", "libx264"}, {"hevc", "libx265"}, {"av1", "libsvtav1"}} {
		t.Run(codec.name, func(t *testing.T) {
			if !bytes.Contains(encoders, []byte(codec.encoder)) {
				t.Skipf("%s is not installed", codec.encoder)
			}
			scratch := t.TempDir()
			t.Setenv("BUNDLE_TEMP_DIR", scratch)
			var data bytes.Buffer
			var mu sync.Mutex
			var completed atomic.Bool
			storage := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.Method {
				case http.MethodPut:
					mu.Lock()
					_, _ = io.Copy(&data, r.Body)
					mu.Unlock()
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
			upload := multipartUpload{PartSizeBytes: 5 * 1024 * 1024, PartURLs: []string{storage.URL + "/video?partNumber=1"}, CompleteURL: storage.URL + "/video", AbortURL: storage.URL + "/video"}
			request := encodeRequest{InputURL: "https://example.test/source.mp4", Codec: codec.name, Width: 320, VideoCRF: 30, Preset: "fast", MaxDurationSeconds: 60}
			if err := request.validate(); err != nil {
				t.Fatal(err)
			}
			request.InputURL = source
			response := httptest.NewRecorder()
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			uploadFaststartVideo(ctx, response, ffmpegArgs(request, "cpu"), upload, nil)
			if !completed.Load() || !strings.Contains(response.Body.String(), `"status":"completed"`) {
				t.Fatalf("upload did not complete: %s", response.Body.String())
			}
			mu.Lock()
			published := bytes.Clone(data.Bytes())
			mu.Unlock()
			assertFaststartMP4(t, published)
			outputPath := filepath.Join(t.TempDir(), "published.mp4")
			if err := os.WriteFile(outputPath, published, 0600); err != nil {
				t.Fatal(err)
			}
			if output, err := exec.Command(ffmpeg, "-v", "error", "-xerror", "-i", outputPath, "-f", "null", "-").CombinedOutput(); err != nil {
				t.Fatalf("published video must decode completely: %v: %s", err, output)
			}
			if ffprobe, err := exec.LookPath("ffprobe"); err == nil {
				frames, err := exec.Command(ffprobe, "-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=nb_read_frames", "-of", "default=nw=1:nk=1", outputPath).Output()
				if err != nil || strings.TrimSpace(string(frames)) != "50" {
					t.Fatalf("published video must preserve all 50 frames: %s (%v)", frames, err)
				}
			}
			entries, _ := os.ReadDir(scratch)
			if len(entries) != 0 {
				t.Fatal("video scratch files were not removed")
			}
		})
	}
}

func TestFaststartUploadFailureRemovesScratchAndAborts(t *testing.T) {
	for _, failure := range []string{"capacity", "canceled", "upload"} {
		t.Run(failure, func(t *testing.T) {
			scratch := t.TempDir()
			t.Setenv("BUNDLE_TEMP_DIR", scratch)
			bin := t.TempDir()
			script := "#!/bin/sh\nfor arg do output=\"$arg\"; done\nprintf encoded-media > \"$output\"\nprintf 'frame=1\\nprogress=end\\n' >&2\n"
			if failure == "canceled" {
				script += "sleep 30\n"
			}
			if err := os.WriteFile(filepath.Join(bin, "ffmpeg"), []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			var uploaded, completed, aborted atomic.Bool
			storage := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.Method {
				case http.MethodPut:
					uploaded.Store(true)
					w.WriteHeader(http.StatusBadRequest)
				case http.MethodPost:
					completed.Store(true)
				case http.MethodDelete:
					aborted.Store(true)
				}
			}))
			defer storage.Close()
			previous := http.DefaultClient
			http.DefaultClient = storage.Client()
			defer func() { http.DefaultClient = previous }()
			upload := multipartUpload{PartSizeBytes: 5 * 1024 * 1024, PartURLs: []string{storage.URL + "/video"}, CompleteURL: storage.URL + "/video", AbortURL: storage.URL + "/video"}
			if failure == "capacity" {
				upload.PartSizeBytes = 1
			}
			timeout := 5 * time.Second
			if failure == "canceled" {
				timeout = 100 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			response := httptest.NewRecorder()
			uploadFaststartVideo(ctx, response, []string{"-movflags", "frag_keyframe", "pipe:1"}, upload, nil)
			if completed.Load() || !aborted.Load() || !strings.Contains(response.Body.String(), `"status":"failed"`) {
				t.Fatalf("failed work must abort: %s", response.Body.String())
			}
			if failure != "upload" && uploaded.Load() {
				t.Fatal("incomplete or oversized output reached storage")
			}
			entries, _ := os.ReadDir(scratch)
			if len(entries) != 0 {
				t.Fatal("failed work left scratch files")
			}
		})
	}
}
