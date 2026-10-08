package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/pem"
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

// A demuxer error can produce a valid, incomplete MP4 and a zero exit status.
// Exercise real FFmpeg and the upload boundary, not just its argument builder.
func TestVideoUploadsRejectIncompleteInputs(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	fixtures := make(map[string][]byte)
	for name, duration := range map[string]string{"complete": "2", "empty": "0"} {
		path := filepath.Join(t.TempDir(), name+".mp4")
		output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
			"testsrc2=size=160x90:rate=10", "-t", duration, "-c:v", "libx264", "-threads", "1",
			"-g", "5", "-movflags", "frag_keyframe+empty_moov+default_base_moof", path).CombinedOutput()
		if err != nil {
			t.Fatalf("generate fixture: %v: %s", err, output)
		}
		fixtures[name], err = os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
	}
	for _, operation := range []string{"concat", "video"} {
		for _, failure := range []string{"none", "http502", "truncated", "empty", "empty_middle"} {
			t.Run(operation+"/"+failure, func(t *testing.T) {
				scratch := t.TempDir()
				t.Setenv("BUNDLE_TEMP_DIR", scratch)
				var reads, ranged atomic.Int32
				source := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					reads.Add(1)
					if r.Header.Get("Range") != "" {
						ranged.Add(1)
					}
					data := fixtures["complete"]
					if r.URL.Path == "/broken.mp4" {
						switch failure {
						case "http502":
							w.WriteHeader(http.StatusBadGateway)
							return
						case "empty", "empty_middle":
							data = fixtures["empty"]
						case "truncated":
							w.Header().Set("Content-Length", strconv.Itoa(len(data)))
							_, _ = w.Write(data[:len(data)/2])
							return
						}
					}
					http.ServeContent(w, r, "chunk.mp4", time.Time{}, bytes.NewReader(data))
				}))
				defer source.Close()
				if operation == "concat" {
					segmentTestSourceClient(t, source.Client())
				}
				// Trust only this fixture certificate in FFmpeg's OpenSSL build.
				certificate := filepath.Join(t.TempDir(), "source.pem")
				if err := os.WriteFile(certificate, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: source.Certificate().Raw}), 0600); err != nil {
					t.Fatal(err)
				}
				// mediaCommand deliberately strips environment variables. Set this
				// test-only CA after that boundary without changing production TLS.
				wrapperDir := t.TempDir()
				quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
				wrapper := "#!/bin/sh\nexport SSL_CERT_FILE=" + quote(certificate) + "\nexec " + quote(ffmpeg) + " \"$@\"\n"
				if err := os.WriteFile(filepath.Join(wrapperDir, "ffmpeg"), []byte(wrapper), 0700); err != nil {
					t.Fatal(err)
				}
				t.Setenv("PATH", wrapperDir+string(os.PathListSeparator)+os.Getenv("PATH"))
				var uploaded, completed, aborted atomic.Bool
				storage := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					switch r.Method {
					case http.MethodPut:
						uploaded.Store(true)
						w.Header().Set("ETag", `"part-1"`)
					case http.MethodPost:
						completed.Store(true)
					case http.MethodDelete:
						aborted.Store(true)
					}
					w.WriteHeader(http.StatusOK)
				}))
				defer storage.Close()
				previous := http.DefaultClient
				http.DefaultClient = storage.Client()
				defer func() { http.DefaultClient = previous }()
				upload := multipartUpload{
					PartSizeBytes: 5 * 1024 * 1024,
					PartURLs:      []string{storage.URL + "/object?partNumber=1&uploadId=test"},
					CompleteURL:   storage.URL + "/object?uploadId=test", AbortURL: storage.URL + "/object?uploadId=test",
				}
				var payload []byte
				var handler http.HandlerFunc
				if operation == "concat" {
					first := source.URL + "/complete.mp4"
					if failure == "empty" {
						first = source.URL + "/broken.mp4"
					}
					payload, err = json.Marshal(concatRequest{InputURLs: []string{first, source.URL + "/broken.mp4"}, OutputUpload: upload})
					handler = concatHandler(10*time.Second, "test", "", nil, newActivityTracker())
				} else {
					payload, err = json.Marshal(encodeRequest{InputURL: source.URL + "/broken.mp4", Operation: "video", Codec: "h264", Width: 320, OutputUpload: &upload})
					handler = encodeHandler(10*time.Second, "test", "cpu", "", nil, newActivityTracker())
				}
				if err != nil {
					t.Fatal(err)
				}
				response := httptest.NewRecorder()
				handler(response, httptest.NewRequest(http.MethodPost, "/"+operation, bytes.NewReader(payload)))
				body := response.Body.String()
				if failure == "none" {
					if !completed.Load() || aborted.Load() || !strings.Contains(body, `"status":"completed"`) {
						t.Fatalf("complete video must succeed: %s", body)
					}
					if operation == "concat" && (reads.Load() != 2 || ranged.Load() != 0 || !strings.Contains(body, `"frame":"40"`)) {
						t.Fatalf("concat must download each source once and retain all packets: %s", body)
					}
				} else if completed.Load() || (uploaded.Load() && !aborted.Load()) || !strings.Contains(body, `"status":"failed"`) {
					t.Fatalf("incomplete video must abort: completed=%v aborted=%v response=%s", completed.Load(), aborted.Load(), body)
				}
				entries, _ := os.ReadDir(scratch)
				if len(entries) != 0 {
					t.Fatal("request left temporary concat media")
				}
			})
		}
	}
}

func TestHLSPackagingRetriesInterruptedReads(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	input := filepath.Join(t.TempDir(), "input.mp4")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10",
		"-t", "8", "-c:v", "libx264", "-threads", "1", "-g", "10", "-movflags", "+faststart", input).CombinedOutput(); err != nil {
		t.Fatalf("generate source: %v: %s", err, output)
	}
	data, err := os.ReadFile(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"http502", "truncated", "persistent502", "forbidden"} {
		t.Run(failure, func(t *testing.T) {
			var reads atomic.Int32
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				attempt := reads.Add(1)
				if failure == "forbidden" {
					w.WriteHeader(http.StatusForbidden)
					return
				}
				if failure == "persistent502" || (failure == "http502" && attempt == 1) {
					w.WriteHeader(http.StatusBadGateway)
					return
				}
				if failure == "truncated" && attempt == 1 {
					w.Header().Set("Content-Length", strconv.Itoa(len(data)))
					_, _ = w.Write(data[:len(data)/2])
					return
				}
				http.ServeContent(w, r, "input.mp4", time.Time{}, bytes.NewReader(data))
			}))
			defer source.Close()
			dir := t.TempDir()
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			output, err := exec.CommandContext(ctx, ffmpeg, hlsArgs(source.URL, dir)...).CombinedOutput()
			if failure == "persistent502" || failure == "forbidden" {
				if err == nil || ctx.Err() != nil {
					t.Fatalf("expected bounded input failure, err=%v: %s", err, output)
				}
				if failure == "forbidden" && reads.Load() != 1 {
					t.Fatalf("authorization failures must not be retried: %d reads", reads.Load())
				}
				if failure == "persistent502" && (reads.Load() < 2 || reads.Load() > 4) {
					t.Fatalf("retry count must be bounded: %d", reads.Load())
				}
				return
			}
			if err != nil || reads.Load() < 2 {
				t.Fatalf("expected recovery after interrupted read: reads=%d err=%v: %s", reads.Load(), err, output)
			}
			playlist, err := os.ReadFile(filepath.Join(dir, "playlist.m3u8"))
			if err != nil || !strings.Contains(string(playlist), "#EXT-X-ENDLIST") {
				t.Fatalf("missing completed playlist: %v", err)
			}
			var duration float64
			for _, line := range strings.Split(string(playlist), "\n") {
				if strings.HasPrefix(line, "#EXTINF:") {
					seconds, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimPrefix(line, "#EXTINF:"), ","), 64)
					duration += seconds
				}
			}
			if duration < 7.99 || duration > 8.01 {
				t.Fatalf("recovered HLS must contain all eight seconds, got %f", duration)
			}
		})
	}
}
