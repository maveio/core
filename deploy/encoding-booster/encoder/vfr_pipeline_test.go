package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func TestSparseVideoAudioChunksRemainIntact(t *testing.T) {
	const sourceSpec = "testsrc2=size=320x180:rate=60:duration=10"
	const filter = "setpts='PTS+floor(N/180)*200/TB'"
	const chunkDuration = 210.0
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	root := t.TempDir()
	t.Setenv("BUNDLE_TEMP_DIR", root)
	dir := filepath.Join(root, "job")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(dir, "source.mp4")
	args := []string{"-v", "error", "-f", "lavfi", "-i", sourceSpec, "-f", "lavfi", "-i", fmt.Sprintf("sine=frequency=440:sample_rate=48000:duration=%.3f", chunkDuration*3), "-map", "0:v:0", "-map", "1:a:0", "-vf", filter, "-fps_mode", "vfr", "-c:v", "libx264", "-preset", "fast", "-threads", "2", "-bf", "0", "-bsf:v", "setts=dts=DTS-5/TB", "-c:a", "aac", "-shortest", "-video_track_timescale", "600", source}
	if out, err := exec.Command(ffmpeg, args...).CombinedOutput(); err != nil {
		t.Fatalf("generate sparse source: %v: %s", err, out)
	}
	var mu sync.Mutex
	parts := map[int][]byte{}
	objects := map[string][]byte{}
	storage := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Method == http.MethodPut {
			n, _ := strconv.Atoi(r.URL.Query().Get("partNumber"))
			parts[n], _ = io.ReadAll(r.Body)
			w.Header().Set("ETag", fmt.Sprintf("\"%d\"", n))
			return
		}
		_, _ = w.Write(objects[r.URL.Path])
	}))
	defer storage.Close()
	segmentTestSourceClient(t, storage.Client())
	previous := http.DefaultClient
	http.DefaultClient = storage.Client()
	t.Cleanup(func() { http.DefaultClient = previous })
	var urls []string
	var expectedFrames int64
	includeAudio := true
	for index := 0; index < 3; index++ {
		request := encodeRequest{InputURL: source, Operation: "video", Codec: "h264", Width: 320, VideoCRF: 20, VideoMaxrate: "4M", VideoBufsize: "8M", Preset: "faster", IncludeAudio: &includeAudio, AudioBitrate: "128k", GOPFrames: 250, KeyframeIntervalSeconds: 2, StartSeconds: float64(index) * chunkDuration, DurationSeconds: chunkDuration}
		encodeArgs := videoFFmpegArgs(request, "cpu")
		command := exec.Command(ffmpeg, encodeArgs...)
		var encoded, diagnostics bytes.Buffer
		command.Stdout, command.Stderr = &encoded, &diagnostics
		if err := command.Run(); err != nil {
			t.Fatalf("encode chunk %d: %v: %s", index, err, diagnostics.String())
		}
		var frames int64
		for _, line := range strings.Split(diagnostics.String(), "\n") {
			if strings.HasPrefix(line, "frame=") {
				frames, _ = strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, "frame=")), 10, 64)
			}
		}
		if frames <= 0 {
			t.Fatal("encoder reported no frames")
		}
		expectedFrames += frames
		t.Logf("chunk %d encoded %d bytes", index, encoded.Len())
		mu.Lock()
		parts = map[int][]byte{}
		mu.Unlock()
		const partSize = 8192
		upload := multipartUpload{PartSizeBytes: int64(partSize)}
		for n := 1; n <= encoded.Len()/partSize+1; n++ {
			upload.PartURLs = append(upload.PartURLs, fmt.Sprintf("%s/part?partNumber=%d", storage.URL, n))
		}
		size, uploaded, err := streamToMultipartUpload(context.Background(), httptest.NewRecorder(), bytes.NewReader(encoded.Bytes()), upload)
		if err != nil {
			t.Fatal(err)
		}
		var stored bytes.Buffer
		mu.Lock()
		for _, part := range uploaded {
			stored.Write(parts[part.PartNumber])
		}
		mu.Unlock()
		if size != int64(encoded.Len()) || !bytes.Equal(stored.Bytes(), encoded.Bytes()) {
			t.Fatalf("chunk %d changed during multipart upload", index)
		}
		name := fmt.Sprintf("/chunk-%d.mp4", index)
		mu.Lock()
		objects[name] = bytes.Clone(stored.Bytes())
		mu.Unlock()
		urls = append(urls, storage.URL+name)
	}
	result := downloadConcatSources(context.Background(), concatRequest{InputURLs: urls}, dir, maxConcatSourceBytes)
	if result.err != nil {
		command := mediaCommand(context.Background(), ffmpeg, "-hide_banner", "-loglevel", "error", "-xerror", "-f", "concat", "-safe", "0", "-i", filepath.Join(dir, "validate.ffconcat"), "-map", "0:v:0", "-c:v", "copy", "-f", "null", "-")
		output, commandErr := command.CombinedOutput()
		t.Fatalf("%v; validation command: %v: %s", result.err, commandErr, output)
	}
	if result.frames != expectedFrames {
		t.Fatalf("stored chunks lost frames: got %d, encoded %d", result.frames, expectedFrames)
	}
	concatArgs := concatFFmpegArgs(concatRequest{})
	for i, arg := range concatArgs {
		if arg == "-i" {
			concatArgs[i+1] = result.manifest
		}
	}
	command := exec.Command(ffmpeg, concatArgs...)
	var combined, diagnostics bytes.Buffer
	command.Stdout, command.Stderr = &combined, &diagnostics
	if err := command.Run(); err != nil {
		t.Fatalf("concat: %v: %s", err, diagnostics.String())
	}
	output := filepath.Join(dir, "combined.mp4")
	if err := os.WriteFile(output, combined.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if frames, err := validateConcatChunk(context.Background(), output, dir); err != nil {
		t.Fatalf("combined output: %v", err)
	} else if frames != expectedFrames {
		t.Fatalf("concat lost frames: got %d, encoded %d", frames, expectedFrames)
	}
	if out, err := exec.Command(ffmpeg, "-v", "error", "-xerror", "-i", output, "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-").CombinedOutput(); err != nil || len(out) != 0 {
		t.Fatalf("decode both tracks: %v: %s", err, out)
	}
}
