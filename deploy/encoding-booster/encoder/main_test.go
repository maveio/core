package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image/png"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type synchronizedResponseRecorder struct {
	mu      sync.Mutex
	header  http.Header
	body    bytes.Buffer
	status  int
	flushes chan struct{}
}

func newSynchronizedResponseRecorder() *synchronizedResponseRecorder {
	return &synchronizedResponseRecorder{
		header:  make(http.Header),
		flushes: make(chan struct{}, 16),
	}
}

func (recorder *synchronizedResponseRecorder) Header() http.Header {
	return recorder.header
}

func (recorder *synchronizedResponseRecorder) WriteHeader(status int) {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	if recorder.status == 0 {
		recorder.status = status
	}
}

func (recorder *synchronizedResponseRecorder) Write(data []byte) (int, error) {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	if recorder.status == 0 {
		recorder.status = http.StatusOK
	}
	return recorder.body.Write(data)
}

func (recorder *synchronizedResponseRecorder) Flush() {
	select {
	case recorder.flushes <- struct{}{}:
	default:
	}
}

func (recorder *synchronizedResponseRecorder) bodyString() string {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	return recorder.body.String()
}

func (recorder *synchronizedResponseRecorder) statusCode() int {
	recorder.mu.Lock()
	defer recorder.mu.Unlock()
	return recorder.status
}

func TestRequestDefaults(t *testing.T) {
	request := encodeRequest{InputURL: "https://example.com/input.webm"}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
	if request.EncodingProfile != productionEncodingProfile || request.Width != 1920 || request.Codec != "h264" || request.VideoBitrate != "8M" || request.AudioBitrate != "192k" || request.Preset != "medium" {
		t.Fatalf("unexpected defaults: %+v", request)
	}
}

func TestRequestAcceptsCoreEncodingOptions(t *testing.T) {
	includeAudio := false
	request := encodeRequest{
		InputURL: "https://example.com/input.webm", InputReferer: "https://ffmpeg.storage.mave.invalid/token", Width: 1280,
		EncodingProfile: productionEncodingProfile,
		VideoBitrate:    "4M", AudioBitrate: "128k", Preset: "veryfast", Tune: "grain",
		IncludeAudio: &includeAudio, KeyframeIntervalSeconds: 2, GOPFrames: 250,
		StartSeconds: 120.5, DurationSeconds: 30.25, MaxDurationSeconds: 10, PackageHLS: true,
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
}

func TestRequestAcceptsLegacyProductionEncodingProfileDuringRollout(t *testing.T) {
	includeAudio := false
	request := encodeRequest{
		InputURL:        "https://example.com/input.webm",
		EncodingProfile: legacyProductionEncodingProfile,
		Codec:           "av1",
		VideoCRF:        38,
		Preset:          "fast",
		SVTAV1Params:    legacyProductionSVTAV1Params,
		IncludeAudio:    &includeAudio,
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
	if request.EncodingProfile != legacyProductionEncodingProfile {
		t.Fatalf("legacy profile should be preserved during rollout: %+v", request)
	}
}

func TestRequestAcceptsAudioAndFrameOperations(t *testing.T) {
	audio := encodeRequest{
		InputURL: "https://example.com/input.webm", Operation: "audio",
		AudioCodec: "mp3", AudioStreamIndex: 2, AudioBitrate: "128k",
	}
	if err := audio.validate(); err != nil {
		t.Fatal(err)
	}

	frame := encodeRequest{
		InputURL: "https://example.com/input.webm", Operation: "frame",
		FrameRole: "thumbnail", FrameCodec: "jpg", StartSeconds: 3.5,
	}
	if err := frame.validate(); err != nil {
		t.Fatal(err)
	}
}

func TestRequestRejectsHLSBundleForNonH264Codec(t *testing.T) {
	request := encodeRequest{
		InputURL: "https://example.com/input.webm", Codec: "hevc", PackageHLS: true,
	}
	if err := request.validate(); err == nil {
		t.Fatal("expected package_hls with HEVC to be rejected")
	}
}

func TestRequestRejectsUnsafeValues(t *testing.T) {
	cases := []encodeRequest{
		{InputURL: "http://example.com/input.webm"},
		{InputURL: "https://user:%0Apassword@example.com/input.webm"},
		{InputURL: "https://" + strings.Repeat("a", 4097) + "@example.com/input.webm"},
		{InputURL: "https://example.com/input.webm", InputReferer: "https://example.com/invalid\r\nX-Evil: true"},
		{InputURL: "https://example.com/input.webm", InputReferer: "http://example.com/referer"},
		{InputURL: "https://example.com/input.webm", Width: 1919},
		{InputURL: "https://example.com/input.webm", Codec: "vp9"},
		{InputURL: "https://example.com/input.webm", EncodingProfile: "space-specific-v1"},
		{InputURL: "https://example.com/input.webm", VideoBitrate: "81M"},
		{InputURL: "https://example.com/input.webm", Codec: "av1", VideoCRF: 64},
		{InputURL: "https://example.com/input.webm", Codec: "av1", VideoCRF: 38, SVTAV1Params: "unsafe=1"},
		{InputURL: "https://example.com/input.webm", Preset: "turbo"},
		{InputURL: "https://example.com/input.webm", Tune: "invalid"},
		{InputURL: "https://example.com/input.webm", KeyframeIntervalSeconds: 61},
		{InputURL: "https://example.com/input.webm", GOPFrames: 10_001},
		{InputURL: "https://example.com/input.webm", MaxDurationSeconds: 86_401},
	}
	for _, request := range cases {
		if err := request.validate(); err == nil {
			t.Fatalf("request should have been rejected: %+v", request)
		}
	}
}

func TestRequestMovesURLBasicAuthIntoFFmpegHeaders(t *testing.T) {
	request := encodeRequest{
		InputURL:     "https://video%40example.com:p%40ssword@example.com/input.webm",
		InputReferer: "https://ffmpeg.storage.mave.invalid/token",
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
	if request.InputURL != "https://example.com/input.webm" {
		t.Fatalf("expected sanitized input URL, got %q", request.InputURL)
	}
	if request.InputBasicAuth != "video@example.com:p@ssword" {
		t.Fatalf("unexpected Basic auth value: %q", request.InputBasicAuth)
	}
	if err := request.validate(); err != nil || request.InputBasicAuth != "video@example.com:p@ssword" {
		t.Fatalf("expected validation to be idempotent: auth=%q err=%v", request.InputBasicAuth, err)
	}

	args := ffmpegArgs(request, "cpu")
	headers := "Referer: https://ffmpeg.storage.mave.invalid/token\r\n" +
		"Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte(request.InputBasicAuth)) + "\r\n"
	if !slices.Contains(args, headers) {
		t.Fatalf("expected combined source headers in FFmpeg arguments: %v", args)
	}
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "p%40ssword") || strings.Contains(joined, "p@ssword") {
		t.Fatalf("FFmpeg input URL must not contain raw credentials: %v", args)
	}

	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(payload, []byte("input_basic_auth")) || bytes.Contains(payload, []byte("p@ssword")) {
		t.Fatalf("normalized credentials must remain internal: %s", payload)
	}
}

func TestRequestAcceptsScopedMultipartDestination(t *testing.T) {
	upload := &multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{"https://storage.example/object?partNumber=1&uploadId=test"},
		CompleteURL:   "https://storage.example/object?uploadId=test",
		AbortURL:      "https://storage.example/object?uploadId=test",
	}
	request := encodeRequest{InputURL: "https://example.com/input.mp4", OutputUpload: upload}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
}

func TestMultipartDestinationRejectsInsecureURLs(t *testing.T) {
	upload := multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{"http://storage.example/object?partNumber=1"},
		CompleteURL:   "https://storage.example/object?uploadId=test",
		AbortURL:      "https://storage.example/object?uploadId=test",
	}
	if err := upload.validate(); err == nil {
		t.Fatal("expected insecure multipart URL to be rejected")
	}
}

func TestTransferRequestRejectsUnsafeInput(t *testing.T) {
	request := transferRequest{InputURL: "http://example.com/input.mp4"}
	if err := request.validate(); err == nil {
		t.Fatal("expected insecure transfer input to be rejected")
	}

	request = transferRequest{
		InputURL:       "https://example.com/input.mp4",
		InputBasicAuth: "user:password\r\nX-Evil: true",
	}
	if err := request.validate(); err == nil {
		t.Fatal("expected unsafe transfer Basic auth to be rejected")
	}
}

func TestPublicSourceIPRejectsInternalAndReservedAddresses(t *testing.T) {
	rejected := []string{
		"127.0.0.1",
		"10.0.0.1",
		"100.64.0.1",
		"169.254.169.254",
		"192.0.2.1",
		"198.18.0.1",
		"203.0.113.1",
		"240.0.0.1",
		"255.255.255.255",
		"::1",
		"fc00::1",
		"fe80::1",
		"2001:db8::1",
	}
	for _, rawIP := range rejected {
		if publicSourceIP(net.ParseIP(rawIP)) {
			t.Fatalf("expected %s to be rejected", rawIP)
		}
	}

	accepted := []string{"93.184.216.34", "2606:4700:4700::1111"}
	for _, rawIP := range accepted {
		if !publicSourceIP(net.ParseIP(rawIP)) {
			t.Fatalf("expected %s to be accepted", rawIP)
		}
	}
}

func TestPublicSourceRequestRejectsPrivateResolution(t *testing.T) {
	previousLookup := lookupSourceIPs
	lookupSourceIPs = func(_ context.Context, _ string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("169.254.169.254")}}, nil
	}
	defer func() { lookupSourceIPs = previousLookup }()

	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, "https://source.example/media.mp4", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := executePublicSourceRequest(request); err == nil {
		t.Fatal("expected private source resolution to be rejected")
	}
}

func TestPublicSourceRequestPinsValidatedPublicAddress(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		_, _ = writer.Write([]byte("remote-original"))
	}))
	defer server.Close()

	previousLookup := lookupSourceIPs
	lookupSourceIPs = func(_ context.Context, _ string) ([]net.IPAddr, error) {
		return []net.IPAddr{{IP: net.ParseIP("93.184.216.34")}}, nil
	}
	defer func() { lookupSourceIPs = previousLookup }()

	previousDial := dialSourceContext
	pinnedAddress := ""
	dialSourceContext = func(ctx context.Context, network string, address string) (net.Conn, error) {
		pinnedAddress = address
		return previousDial(ctx, network, server.Listener.Addr().String())
	}
	defer func() { dialSourceContext = previousDial }()

	previousTransport := http.DefaultTransport
	http.DefaultTransport = server.Client().Transport
	defer func() { http.DefaultTransport = previousTransport }()

	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL+"/media.mp4", nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := executePublicSourceRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "remote-original" {
		t.Fatalf("unexpected source body: %q", body)
	}
	_, port, err := net.SplitHostPort(server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	if pinnedAddress != net.JoinHostPort("93.184.216.34", port) {
		t.Fatalf("expected validated address to be pinned, got %q", pinnedAddress)
	}
}

func TestPublicSourceClientRejectsRedirects(t *testing.T) {
	client, err := publicSourceHTTPClient("source.example", "93.184.216.34")
	if err != nil {
		t.Fatal(err)
	}
	if err := client.CheckRedirect(nil, nil); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("expected redirects to be rejected, got %v", err)
	}
}

func TestStreamsOutputIntoMultipartStorage(t *testing.T) {
	var uploaded atomic.Int64
	var completed atomic.Bool
	storage := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.Method {
		case http.MethodPut:
			body, _ := io.ReadAll(request.Body)
			uploaded.Add(int64(len(body)))
			writer.Header().Set("ETag", `"part-1"`)
			writer.WriteHeader(http.StatusOK)
		case http.MethodPost:
			completed.Store(true)
			writer.WriteHeader(http.StatusOK)
		case http.MethodDelete:
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer storage.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = storage.Client()
	defer func() { http.DefaultClient = oldClient }()

	upload := multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{storage.URL + "/object?partNumber=1&uploadId=test"},
		CompleteURL:   storage.URL + "/object?uploadId=test",
		AbortURL:      storage.URL + "/object?uploadId=test",
	}
	response := httptest.NewRecorder()
	size, parts, err := streamToMultipartUpload(context.Background(), response, strings.NewReader("encoded-media"), upload)
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len("encoded-media")) || uploaded.Load() != size || len(parts) != 1 {
		t.Fatalf("unexpected multipart result: size=%d uploaded=%d parts=%+v", size, uploaded.Load(), parts)
	}
	if err := completeMultipartUpload(context.Background(), upload.CompleteURL, parts); err != nil {
		t.Fatal(err)
	}
	if !completed.Load() {
		t.Fatal("expected multipart completion request")
	}
	if !strings.Contains(response.Body.String(), `"status":"uploading"`) {
		t.Fatalf("expected progress response, got %q", response.Body.String())
	}
}

func TestMultipartStorageFlushesStartedEventAndHeartbeatsWhileWaitingForOutput(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	reader, writer := io.Pipe()
	defer writer.Close()

	response := newSynchronizedResponseRecorder()
	done := make(chan error, 1)
	go func() {
		_, _, err := streamToMultipartUploadWithHeartbeat(
			ctx,
			response,
			reader,
			multipartUpload{
				PartSizeBytes: 5 * 1024 * 1024,
				PartURLs:      []string{"https://storage.example/part"},
			},
			5*time.Millisecond,
		)
		done <- err
	}()

	waitForFlush(t, response.flushes, "started event")
	if body := response.bodyString(); !strings.Contains(body, `"status":"started"`) {
		t.Fatalf("expected immediate started event, got %q", body)
	}

	waitForFlush(t, response.flushes, "heartbeat event")
	if body := response.bodyString(); !strings.Contains(body, `"status":"uploading"`) {
		t.Fatalf("expected heartbeat while waiting for output, got %q", body)
	}

	cancel()
	_ = writer.Close()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) && !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("expected cancelled stream, got %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for cancelled multipart stream")
	}
}

func TestEncodeHandlerFlushesStartedEventBeforeFFmpegProducesOutput(t *testing.T) {
	ffmpegDir := t.TempDir()
	ffmpegPath := filepath.Join(ffmpegDir, "ffmpeg")
	ffmpegScript := `#!/bin/sh
sleep 1
printf encoded-media
`
	if err := os.WriteFile(ffmpegPath, []byte(ffmpegScript), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", ffmpegDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	storage := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.Method {
		case http.MethodPut:
			writer.Header().Set("ETag", `"part-1"`)
			writer.WriteHeader(http.StatusOK)
		case http.MethodPost:
			writer.WriteHeader(http.StatusOK)
		case http.MethodDelete:
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer storage.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = storage.Client()
	defer func() { http.DefaultClient = oldClient }()

	payload, err := json.Marshal(encodeRequest{
		InputURL: "https://example.com/input.mp4",
		OutputUpload: &multipartUpload{
			PartSizeBytes: 5 * 1024 * 1024,
			PartURLs:      []string{storage.URL + "/object?partNumber=1&uploadId=test"},
			CompleteURL:   storage.URL + "/object?uploadId=test",
			AbortURL:      storage.URL + "/object?uploadId=test",
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	handler := encodeHandler(3*time.Second, "heartbeat-test", "cpu", "", requestSlots(0), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/encode", bytes.NewReader(payload))
	response := newSynchronizedResponseRecorder()
	done := make(chan struct{})
	go func() {
		handler.ServeHTTP(response, request)
		close(done)
	}()

	select {
	case <-response.flushes:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("started event was not flushed before FFmpeg produced output")
	}
	if body := response.bodyString(); !strings.Contains(body, `"status":"started"`) {
		t.Fatalf("expected started event before FFmpeg output, got %q", body)
	}

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for encode handler")
	}
	if response.statusCode() != http.StatusOK {
		t.Fatalf("unexpected response status: %d", response.statusCode())
	}
	if body := response.bodyString(); !strings.Contains(body, `"status":"completed"`) {
		t.Fatalf("expected completed event, got %q", body)
	}
}

func TestEncodeHandlerRejectsAudioWithoutEncodedFrames(t *testing.T) {
	ffmpegDir := t.TempDir()
	ffmpegPath := filepath.Join(ffmpegDir, "ffmpeg")
	ffmpegScript := `#!/bin/sh
printf ID3-only-header
printf 'out_time_ms=0\nprogress=end\n' >&2
`
	if err := os.WriteFile(ffmpegPath, []byte(ffmpegScript), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", ffmpegDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var completed atomic.Bool
	var aborted atomic.Bool
	storage := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.Method {
		case http.MethodPut:
			writer.Header().Set("ETag", `"part-1"`)
			writer.WriteHeader(http.StatusOK)
		case http.MethodPost:
			completed.Store(true)
			writer.WriteHeader(http.StatusOK)
		case http.MethodDelete:
			aborted.Store(true)
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer storage.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = storage.Client()
	defer func() { http.DefaultClient = oldClient }()

	payload, err := json.Marshal(encodeRequest{
		InputURL:   "https://example.com/input.mp4",
		Operation:  "audio",
		AudioCodec: "mp3",
		OutputUpload: &multipartUpload{
			PartSizeBytes: 5 * 1024 * 1024,
			PartURLs:      []string{storage.URL + "/object?partNumber=1&uploadId=test"},
			CompleteURL:   storage.URL + "/object?uploadId=test",
			AbortURL:      storage.URL + "/object?uploadId=test",
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	handler := encodeHandler(3*time.Second, "audio-validation-test", "cpu", "", requestSlots(0), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/encode", bytes.NewReader(payload))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	body := response.Body.String()
	if !strings.Contains(body, `"status":"failed"`) || !strings.Contains(body, "ffmpeg produced no audio frames") {
		t.Fatalf("expected audio validation failure, got %q", body)
	}
	if completed.Load() {
		t.Fatal("invalid audio multipart upload must not be completed")
	}
	if !aborted.Load() {
		t.Fatal("invalid audio multipart upload must be aborted")
	}
}

func TestEncodeMultipartAssetAcceptsShortFFmpegOutput(t *testing.T) {
	ffmpegDir := t.TempDir()
	ffmpegPath := filepath.Join(ffmpegDir, "ffmpeg")
	if err := os.WriteFile(ffmpegPath, []byte("#!/bin/sh\nprintf short-frame\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", ffmpegDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var uploaded atomic.Int64
	var completed atomic.Bool
	storage := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.Method {
		case http.MethodPut:
			body, _ := io.ReadAll(request.Body)
			uploaded.Add(int64(len(body)))
			writer.Header().Set("ETag", `"part-1"`)
			writer.WriteHeader(http.StatusOK)
		case http.MethodPost:
			completed.Store(true)
			writer.WriteHeader(http.StatusOK)
		case http.MethodDelete:
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	defer storage.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = storage.Client()
	defer func() { http.DefaultClient = oldClient }()

	upload := multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{storage.URL + "/object?partNumber=1&uploadId=test"},
		CompleteURL:   storage.URL + "/object?uploadId=test",
		AbortURL:      storage.URL + "/object?uploadId=test",
	}
	response := httptest.NewRecorder()
	size, _, _, err := encodeMultipartAsset(
		context.Background(),
		response,
		encodeRequest{
			InputURL:   "https://example.com/input.mp4",
			Operation:  "frame",
			FrameRole:  "segment",
			FrameCodec: "jpg",
		},
		"cpu",
		upload,
	)
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len("short-frame")) || uploaded.Load() != size || !completed.Load() {
		t.Fatalf(
			"short output did not complete: size=%d uploaded=%d completed=%v",
			size,
			uploaded.Load(),
			completed.Load(),
		)
	}
}

func waitForFlush(t *testing.T, flushes <-chan struct{}, label string) {
	t.Helper()
	select {
	case <-flushes:
	case <-time.After(time.Second):
		t.Fatalf("timed out waiting for %s", label)
	}
}

func TestTransferStreamsRemoteSourceIntoMultipartStorage(t *testing.T) {
	var uploaded atomic.Int64
	var completed atomic.Bool
	var receivedAuthorization atomic.Value
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/source":
			receivedAuthorization.Store(request.Header.Get("Authorization"))
			_, _ = writer.Write([]byte("remote-original"))
		case request.Method == http.MethodPut && request.URL.Path == "/object":
			body, _ := io.ReadAll(request.Body)
			uploaded.Add(int64(len(body)))
			writer.Header().Set("ETag", `"part-1"`)
			writer.WriteHeader(http.StatusOK)
		case request.Method == http.MethodPost && request.URL.Path == "/object":
			completed.Store(true)
			writer.WriteHeader(http.StatusOK)
		case request.Method == http.MethodDelete && request.URL.Path == "/object":
			writer.WriteHeader(http.StatusNoContent)
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = server.Client()
	defer func() { http.DefaultClient = oldClient }()
	previousSourceRequest := performSourceRequest
	performSourceRequest = server.Client().Do
	defer func() { performSourceRequest = previousSourceRequest }()

	payload, _ := json.Marshal(transferRequest{
		InputURL:       server.URL + "/source",
		InputBasicAuth: "video@example.com:p@ssword",
		OutputUpload: multipartUpload{
			PartSizeBytes: 5 * 1024 * 1024,
			PartURLs:      []string{server.URL + "/object?partNumber=1&uploadId=test"},
			CompleteURL:   server.URL + "/object?uploadId=test",
			AbortURL:      server.URL + "/object?uploadId=test",
		},
	})
	request := httptest.NewRequest(http.MethodPost, "/transfer", bytes.NewReader(payload))
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()

	transferHandler(time.Second, "transfer-test", "secret-token", requestSlots(1), newActivityTracker())(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
	if uploaded.Load() != int64(len("remote-original")) || !completed.Load() {
		t.Fatalf("transfer did not complete: uploaded=%d completed=%v", uploaded.Load(), completed.Load())
	}
	if receivedAuthorization.Load() != "Basic dmlkZW9AZXhhbXBsZS5jb206cEBzc3dvcmQ=" {
		t.Fatalf("unexpected source authorization: %q", receivedAuthorization.Load())
	}
	if !strings.Contains(response.Body.String(), `"status":"completed"`) {
		t.Fatalf("expected completion event, got %q", response.Body.String())
	}
	expectedSHA256 := sha256.Sum256([]byte("remote-original"))
	if !strings.Contains(response.Body.String(), `"sha256":"`+hex.EncodeToString(expectedSHA256[:])+`"`) {
		t.Fatalf("expected source sha256 in completion event, got %q", response.Body.String())
	}
}

func TestConcatUsesRemoteInputsAndPipedOutput(t *testing.T) {
	request := concatRequest{
		InputURLs: []string{"https://storage.example/chunk-1.mp4", "https://storage.example/chunk-2.mp4"},
	}
	args := concatFFmpegArgs(request)
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-f concat") || !strings.Contains(joined, "-i pipe:0") || !strings.Contains(joined, "-f mp4 pipe:1") {
		t.Fatalf("unexpected concat arguments: %v", args)
	}
	manifest := concatManifest(request.InputURLs)
	for _, inputURL := range request.InputURLs {
		if !strings.Contains(manifest, inputURL) {
			t.Fatalf("manifest does not contain %q: %s", inputURL, manifest)
		}
	}
}

func TestFFmpegUsesCoreEncodingOptions(t *testing.T) {
	includeAudio := false
	request := encodeRequest{
		InputURL: "https://example.com/input.webm", InputReferer: "https://ffmpeg.storage.mave.invalid/token", Width: 1280,
		VideoBitrate: "4M", AudioBitrate: "128k", Preset: "veryfast", Tune: "grain",
		IncludeAudio: &includeAudio, KeyframeIntervalSeconds: 2, GOPFrames: 250,
		StartSeconds: 120.5, DurationSeconds: 30.25,
	}
	args := ffmpegArgs(request, "cpu")
	expectedScale := "scale=iw*sar:ih,setsar=1,scale=w=1280:h=1280:force_original_aspect_ratio=decrease:force_divisible_by=2"
	for _, expected := range []string{"-headers", "Referer: https://ffmpeg.storage.mave.invalid/token\r\n", "-ss", "120.500", "-tune", "grain", "-force_key_frames", "expr:gte(t,n_forced*2)", "-g", "250", "-an", "-t", "30.250"} {
		if !slices.Contains(args, expected) {
			t.Fatalf("expected argument %q is missing: %v", expected, args)
		}
	}
	if !slices.Contains(args, expectedScale) {
		t.Fatalf("expected encoder-safe long-edge scale filter %q is missing: %v", expectedScale, args)
	}
	if slices.Contains(args, "-c:a") {
		t.Fatalf("audio encoder should be disabled: %v", args)
	}
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-map_metadata -1 -map 0:v:0") {
		t.Fatalf("video mapping and metadata stripping are missing: %v", args)
	}
	if !strings.Contains(joined, "-format_whitelist "+safeInputFormats) {
		t.Fatalf("primary input demuxer allowlist is missing: %v", args)
	}
}

func TestFFmpegBuildsProductionCodecProfiles(t *testing.T) {
	includeAudio := true
	h264 := encodeRequest{
		InputURL: "https://example.com/input.webm", EncodingProfile: productionEncodingProfile,
		Codec: "h264", Width: 1280, VideoBitrate: "4M", VideoCRF: 23,
		AudioBitrate: "128k", Preset: "medium", IncludeAudio: &includeAudio, GOPFrames: 2,
	}
	if err := h264.validate(); err != nil {
		t.Fatal(err)
	}
	h264Args := strings.Join(ffmpegArgs(h264, "cpu"), " ")
	for _, expected := range []string{"-b:v 4M", "-crf 23", "-preset medium", "-g 2", "-map 0:a?"} {
		if !strings.Contains(h264Args, expected) {
			t.Fatalf("expected H264 profile option %q is missing: %s", expected, h264Args)
		}
	}
	if strings.Contains(h264Args, "-force_key_frames") {
		t.Fatalf("H264 clip should not add a time-based keyframe cadence: %s", h264Args)
	}

	includeAudio = false
	hevc := encodeRequest{
		InputURL: "https://example.com/input.webm", EncodingProfile: productionEncodingProfile,
		Codec: "hevc", Width: 1920, VideoCRF: 24, AudioBitrate: "128k", Preset: "medium",
		Tune: "grain", IncludeAudio: &includeAudio,
	}
	if err := hevc.validate(); err != nil {
		t.Fatal(err)
	}
	hevcArgs := strings.Join(ffmpegArgs(hevc, "cpu"), " ")
	for _, expected := range []string{"-c:v libx265", "-preset medium", "-tune grain", "-crf 24", "-an"} {
		if !strings.Contains(hevcArgs, expected) {
			t.Fatalf("expected HEVC profile option %q is missing: %s", expected, hevcArgs)
		}
	}
	if strings.Contains(hevcArgs, "-b:v") {
		t.Fatalf("HEVC production profile should use constant-quality rate control: %s", hevcArgs)
	}

	hevcNVENCArgs := strings.Join(ffmpegArgs(hevc, "nvenc"), " ")
	if !strings.Contains(hevcNVENCArgs, "-preset p4") || !strings.Contains(hevcNVENCArgs, "-cq 24") || strings.Contains(hevcNVENCArgs, "-tune") {
		t.Fatalf("NVENC should translate the HEVC quality profile: %s", hevcNVENCArgs)
	}

	av1 := encodeRequest{
		InputURL: "https://example.com/input.webm", EncodingProfile: productionEncodingProfile,
		Codec: "av1", Width: 1920, VideoCRF: 26, AudioBitrate: "128k", Preset: "slow",
		SVTAV1Params: productionSVTAV1Params, IncludeAudio: &includeAudio, GOPFrames: 250,
	}
	if err := av1.validate(); err != nil {
		t.Fatal(err)
	}
	av1Args := strings.Join(ffmpegArgs(av1, "cpu"), " ")
	for _, expected := range []string{"-c:v libsvtav1", "-preset 6", "-crf 26", "-svtav1-params " + productionSVTAV1Params, "-g 250", "-an"} {
		if !strings.Contains(av1Args, expected) {
			t.Fatalf("expected AV1 profile option %q is missing: %s", expected, av1Args)
		}
	}
	if strings.Contains(av1Args, "-b:v") || strings.Contains(av1Args, "-force_key_frames") {
		t.Fatalf("AV1 production profile should use CRF without forced cadence: %s", av1Args)
	}

	nvencArgs := strings.Join(ffmpegArgs(av1, "nvenc"), " ")
	if !strings.Contains(nvencArgs, "-preset p5") || !strings.Contains(nvencArgs, "-cq 26") || strings.Contains(nvencArgs, "-svtav1-params") {
		t.Fatalf("NVENC should translate CRF to CQ and omit CPU-only SVT parameters: %s", nvencArgs)
	}
}

func TestFFmpegBuildsPipedAudioAndFrameCommands(t *testing.T) {
	audio := encodeRequest{
		InputURL: "https://example.com/input.webm", Operation: "audio",
		AudioCodec: "mp3", AudioStreamIndex: 1, AudioBitrate: "128k",
	}
	if err := audio.validate(); err != nil {
		t.Fatal(err)
	}
	audioArgs := ffmpegArgs(audio, "cpu")
	for _, expected := range []string{"0:a:1", "libmp3lame", "mp3", "pipe:1"} {
		if !slices.Contains(audioArgs, expected) {
			t.Fatalf("expected audio argument %q is missing: %v", expected, audioArgs)
		}
	}

	frame := encodeRequest{
		InputURL: "https://example.com/input.webm", Operation: "frame",
		FrameRole: "thumbnail", FrameCodec: "jpg",
	}
	if err := frame.validate(); err != nil {
		t.Fatal(err)
	}
	frameArgs := ffmpegArgs(frame, "cpu")
	for _, expected := range []string{"mjpeg", "image2pipe", "pipe:1"} {
		if !slices.Contains(frameArgs, expected) {
			t.Fatalf("expected frame argument %q is missing: %v", expected, frameArgs)
		}
	}
}

func TestWaveformRendersNeutralDotsWithAudioAcrossChunks(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	source := filepath.Join(t.TempDir(), "audio.wav")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
		"sine=frequency=440:duration=4", "-af", "adelay=500:all=1", source).CombinedOutput(); err != nil {
		t.Fatalf("generate audio: %v: %s", err, output)
	}

	for _, start := range []float64{0, 3} {
		t.Run(fmt.Sprintf("start_%g", start), func(t *testing.T) {
			includeAudio := true
			args := waveformFFmpegArgs(encodeRequest{InputURL: source, StartSeconds: start, DurationSeconds: 0.5, IncludeAudio: &includeAudio})
			command := exec.Command(ffmpeg, args...)
			var stderr bytes.Buffer
			command.Stderr = &stderr
			video, err := command.Output()
			if err != nil {
				t.Fatalf("render waveform: %v: %s", err, stderr.String())
			}
			path := filepath.Join(t.TempDir(), "waveform.mp4")
			if err := os.WriteFile(path, video, 0600); err != nil {
				t.Fatal(err)
			}
			probe, err := exec.Command("ffprobe", "-v", "error", "-show_streams", "-of", "json", path).Output()
			if err != nil {
				t.Fatalf("probe waveform: %v", err)
			}
			var info struct {
				Streams []struct {
					Codec string `json:"codec_name"`
					SAR   string `json:"sample_aspect_ratio"`
					DAR   string `json:"display_aspect_ratio"`
				} `json:"streams"`
			}
			if err := json.Unmarshal(probe, &info); err != nil {
				t.Fatal(err)
			}
			if len(info.Streams) != 2 || info.Streams[0].Codec != "h264" || info.Streams[1].Codec != "aac" ||
				info.Streams[0].SAR != "1:1" || info.Streams[0].DAR != "16:9" {
				t.Fatalf("expected square-pixel 16:9 H264 with AAC: %s", probe)
			}
			pcm, err := exec.Command(ffmpeg, "-v", "error", "-i", path, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "s16le", "pipe:1").Output()
			if err != nil || len(pcm) < 48000 || len(pcm) > 54000 {
				t.Fatalf("expected half a second of decoded audio: %v (%d bytes)", err, len(pcm))
			}
			peak := 0
			for i := 0; i+1 < len(pcm); i += 2 {
				sample := int(int16(uint16(pcm[i]) | uint16(pcm[i+1])<<8))
				peak = max(peak, sample, -sample)
			}
			if (start == 0 && peak > 100) || (start == 3 && peak < 1000) {
				t.Fatalf("audio must stay aligned when trimming FFT warm-up (peak %d)", peak)
			}
			pixels, err := exec.Command(ffmpeg, "-v", "error", "-i", path, "-frames:v", "1",
				"-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1").Output()
			if err != nil || len(pixels) != 640*360*3 {
				t.Fatalf("decode 640x360 waveform: %v (%d bytes)", err, len(pixels))
			}
			for i := 0; i < len(pixels); i += 3 {
				low := min(pixels[i], pixels[i+1], pixels[i+2])
				high := max(pixels[i], pixels[i+1], pixels[i+2])
				if high-low > 5 {
					t.Fatalf("waveform has a color tint at pixel %d", i/3)
				}
			}
			if pixels[(180*640+68)*3] < 100 {
				t.Fatal("silent sections must retain the dotted baseline")
			}
			if start == 3 && slices.Max(waveformBarHeights(pixels)) < 15 {
				t.Fatal("a later chunk must immediately respond to the current tone")
			}
			if start == 0 && pixels[(150*640+68)*3] > 20 {
				t.Fatal("leading silence must render only the baseline")
			}
			if start == 0 {
				minX, minY, maxX, maxY := 72, 184, 64, 176
				for y := 176; y < 184; y++ {
					for x := 64; x < 72; x++ {
						if pixels[(y*640+x)*3] > 100 {
							minX, minY, maxX, maxY = min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)
						}
					}
				}
				if maxX-minX != 3 || maxY-minY != 3 {
					t.Fatalf("silent dots must be round 4x4 points, got %dx%d", maxX-minX+1, maxY-minY+1)
				}
			}
		})
	}
}

func waveformBarHeights(pixels []byte) []int {
	heights := make([]int, 64)
	for bar := range heights {
		for y := 100; y < 180; y++ {
			if pixels[(y*640+68+8*bar)*3] > 100 {
				heights[bar]++
			}
		}
	}
	return heights
}

func TestWaveformBarsRiseAndFallInPlace(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	source := filepath.Join(t.TempDir(), "changing-volume.wav")
	// One fixed tone: silence, loud, quiet, then silence again.
	envelope := `aevalsrc=0.4*sin(2*PI*440*t)*if(between(t\,0.3\,0.9)\,1\,if(between(t\,1.2\,1.8)\,0.125\,0)):s=48000:d=2.4`
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", envelope, source).CombinedOutput(); err != nil {
		t.Fatalf("generate changing-volume tone: %v: %s", err, output)
	}
	command := exec.Command(ffmpeg, waveformFFmpegArgs(encodeRequest{InputURL: source})...)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	video, err := command.Output()
	if err != nil {
		t.Fatalf("render reactive waveform: %v: %s", err, stderr.String())
	}
	path := filepath.Join(t.TempDir(), "reactive.mp4")
	if err := os.WriteFile(path, video, 0600); err != nil {
		t.Fatal(err)
	}
	var heights [][]int
	for _, timestamp := range []string{"0.1", "0.65", "1.55", "2.25"} {
		pixels, err := exec.Command(ffmpeg, "-v", "error", "-ss", timestamp, "-i", path,
			"-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1").Output()
		if err != nil || len(pixels) != 640*360*3 {
			t.Fatalf("decode frame at %s: %v (%d bytes)", timestamp, err, len(pixels))
		}
		heights = append(heights, waveformBarHeights(pixels))
	}
	loud, quiet := slices.Max(heights[1]), slices.Max(heights[2])
	if loud < 30 || quiet < 5 || quiet*4 >= loud*3 {
		t.Fatalf("bars must rise and fall with volume, got loud=%d quiet=%d", loud, quiet)
	}
	if slices.Index(heights[1], loud) != slices.Index(heights[2], quiet) {
		t.Fatal("the same tone must animate the same bar, without scrolling horizontally")
	}
	if slices.Max(heights[0]) > 3 || slices.Max(heights[3]) > 3 {
		t.Fatal("silence must return to dots, without retaining past sound on screen")
	}
}

func TestWaveformPeakDoesNotStickAfterSilence(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	dir := t.TempDir()
	source := filepath.Join(dir, "peak.wav")
	// This peak reaches y=0 in showfreqs. Its temporal averaging previously
	// divided by zero there and permanently pinned the band at maximum height.
	envelope := `aevalsrc=sin(2*PI*93.75*t)*if(between(t\,0.3\,0.9)\,0.49\,if(between(t\,1.2\,1.8)\,0.03\,0)):s=48000:d=2.4`
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", envelope, source).CombinedOutput(); err != nil {
		t.Fatalf("generate peak followed by silence: %v: %s", err, output)
	}
	path := filepath.Join(dir, "peak.mp4")
	request := encodeRequest{InputURL: source, Operation: "waveform"}
	if output, err := exec.Command(ffmpeg, ffmpegArgsForOutput(request, "cpu", path)...).CombinedOutput(); err != nil {
		t.Fatalf("render waveform peak: %v: %s", err, output)
	}
	for _, sample := range []struct {
		timestamp string
		maxHeight int
	}{{"1.55", 45}, {"2.25", 3}} {
		pixels, err := exec.Command(ffmpeg, "-v", "error", "-ss", sample.timestamp, "-i", path,
			"-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1").Output()
		if err != nil || len(pixels) != 640*360*3 {
			t.Fatalf("decode waveform at %s: %v (%d bytes)", sample.timestamp, err, len(pixels))
		}
		if height := slices.Max(waveformBarHeights(pixels)); height > sample.maxHeight {
			t.Fatalf("peak must release at %ss, got height %d (maximum %d)", sample.timestamp, height, sample.maxHeight)
		}
	}
}

func TestFFmpegBuildsStorageDirectWaveformAndStoryboardCommands(t *testing.T) {
	waveform := encodeRequest{
		InputURL: "https://example.com/audio.mp3", Operation: "waveform",
		Codec: "h264", StartSeconds: 600, DurationSeconds: 300,
		OutputUpload: testMultipartUpload("waveform.mp4"),
	}
	if err := waveform.validate(); err != nil {
		t.Fatal(err)
	}
	waveformArgs := ffmpegArgs(waveform, "cpu")
	for _, expected := range []string{"-ss", "599.800", "-t", "300.000", "libx264", "frag_keyframe+empty_moov+default_base_moof", "pipe:1"} {
		if !slices.Contains(waveformArgs, expected) {
			t.Fatalf("expected waveform argument %q is missing: %v", expected, waveformArgs)
		}
	}
	if !strings.Contains(strings.Join(waveformArgs, " "), "showfreqs=s=64x160:r=30") {
		t.Fatalf("expected waveform filter is missing: %v", waveformArgs)
	}
	if !strings.Contains(strings.Join(waveformArgs, " "), "trim=start=0.200000,setpts=PTS-STARTPTS[v]") {
		t.Fatalf("expected FFT warm-up to be removed from output: %v", waveformArgs)
	}

	storyboard := encodeRequest{
		InputURL: "https://example.com/video.mp4", Operation: "storyboard",
		FrameCodec: "jpg", DurationSeconds: 5126.130736,
		OutputUpload: testMultipartUpload("storyboard.jpg"),
	}
	if err := storyboard.validate(); err != nil {
		t.Fatal(err)
	}
	if storyboard.Count != 60 {
		t.Fatalf("expected the default storyboard count to be 60, got %d", storyboard.Count)
	}
	storyboardArgs := ffmpegArgs(storyboard, "cpu")
	joined := strings.Join(storyboardArgs, " ")
	if !strings.Contains(joined, "fps=1/85.436") || !strings.Contains(joined, "scale=320:-2,setsar=1") || !strings.Contains(joined, "tile=10x6") {
		t.Fatalf("unexpected storyboard arguments: %v", storyboardArgs)
	}
	if strings.Contains(joined, "pad=320:180") {
		t.Fatalf("storyboard tiles should retain their source aspect ratio: %v", storyboardArgs)
	}
	if !strings.Contains(joined, "-strict unofficial -q:v 6") {
		t.Fatalf("JPEG storyboards should permit FFmpeg's limited-range MJPEG output: %v", storyboardArgs)
	}

	posterArgs := strings.Join(frameFFmpegArgs(encodeRequest{FrameRole: "poster", FrameCodec: "jpg"}), " ")
	if !strings.Contains(posterArgs, "-strict unofficial -q:v 6") {
		t.Fatalf("JPEG frames should permit FFmpeg's limited-range MJPEG output: %s", posterArgs)
	}

	placeholderArgs := strings.Join(frameFFmpegArgs(encodeRequest{FrameRole: "placeholder", FrameCodec: "jpg"}), " ")
	if !strings.Contains(placeholderArgs, "-strict unofficial -q:v 2") {
		t.Fatalf("placeholder JPEG quality regressed: %s", placeholderArgs)
	}
	if !strings.Contains(placeholderArgs, "-i "+placeholderOverlayPath()+" ") {
		t.Fatalf("placeholder overlay should use the bundled image: %s", placeholderArgs)
	}

	segmentArgs := strings.Join(frameFFmpegArgs(encodeRequest{FrameRole: "segment", FrameCodec: "webp"}), " ")
	if !strings.Contains(segmentArgs, "-quality 80") {
		t.Fatalf("segment WebP quality regressed: %s", segmentArgs)
	}
}

func TestSegmentsRequireOrderedIndependentStorageDestinations(t *testing.T) {
	request := encodeRequest{
		InputURL: "https://example.com/video.mp4", Operation: "segments",
		FrameCodec: "jpg", Count: 2, DurationSeconds: 60,
		OutputUploads: []assetUpload{
			{Name: "thumbnail_0.jpg", OutputUpload: *testMultipartUpload("thumbnail_0.jpg")},
			{Name: "thumbnail_1.jpg", OutputUpload: *testMultipartUpload("thumbnail_1.jpg")},
		},
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}

	request.OutputUploads[1].Name = "thumbnail_9.jpg"
	if err := request.validate(); err == nil {
		t.Fatal("expected unordered segment output to be rejected")
	}
}

func testMultipartUpload(name string) *multipartUpload {
	path := "https://storage.example/" + name
	return &multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{path + "?partNumber=1&uploadId=test"},
		CompleteURL:   path + "?uploadId=test",
		AbortURL:      path + "?uploadId=test",
	}
}

func TestPlaceholderOverlayMatchesCoreImage(t *testing.T) {
	config, err := png.DecodeConfig(bytes.NewReader(placeholderOverlayPNG))
	if err != nil || config.Width != 270 || config.Height != 330 {
		t.Fatalf("expected the embedded 270x330 play button, got %+v: %v", config, err)
	}
	// The Docker build context contains only this directory.
	core, err := os.ReadFile(filepath.Join("..", "..", "..", "priv", "static", "images", "play.png"))
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("Core's image is outside the build context")
	}
	if err != nil || !bytes.Equal(core, placeholderOverlayPNG) {
		t.Fatalf("embedded overlay must match Core's priv/static/images/play.png: %v", err)
	}
}

func TestWritePlaceholderOverlayReplacesExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), placeholderOverlayName)
	if err := os.WriteFile(path, []byte("stale"), 0o444); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := writePlaceholderOverlay(path); err != nil {
			t.Fatalf("write overlay: %v", err)
		}
	}
	written, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(written, placeholderOverlayPNG) {
		t.Fatalf("expected the embedded overlay at %s: %v", path, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o444 {
		t.Fatalf("expected a read-only overlay, got %v: %v", info.Mode(), err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("expected no temporary files to remain: %v %v", entries, err)
	}
}

func TestPlaceholderFrameRendersBundledOverlay(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	t.Setenv("BUNDLE_TEMP_DIR", t.TempDir())
	if err := writePlaceholderOverlay(placeholderOverlayPath()); err != nil {
		t.Fatalf("write overlay: %v", err)
	}
	dir := t.TempDir()
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "color=c=black:s=640x360",
		"-frames:v", "1", filepath.Join(dir, "source.jpg")).CombinedOutput(); err != nil {
		t.Fatalf("generate source JPEG: %v: %s", err, output)
	}
	source := httptest.NewServer(http.FileServer(http.Dir(dir)))
	t.Cleanup(source.Close)

	outputPath := filepath.Join(t.TempDir(), "placeholder.jpg")
	request := encodeRequest{
		InputURL: source.URL + "/source.jpg", Operation: "frame",
		FrameRole: "placeholder", FrameCodec: "jpg",
	}
	if output, err := exec.Command(ffmpeg, ffmpegArgsForOutput(request, "cpu", outputPath)...).CombinedOutput(); err != nil {
		t.Fatalf("render placeholder: %v: %s", err, output)
	}
	pixels, err := exec.Command(ffmpeg, "-v", "error", "-i", outputPath, "-frames:v", "1",
		"-vf", "format=gray", "-f", "rawvideo", "pipe:1").Output()
	if err != nil || len(pixels) != 640*360 {
		t.Fatalf("expected a decodable 640x360 placeholder: %v (%d bytes)", err, len(pixels))
	}
	brightest := byte(0)
	for _, value := range pixels {
		brightest = max(brightest, value)
	}
	if brightest < 128 {
		t.Fatalf("expected the play button over the black source, brightest pixel %d", brightest)
	}
}

func TestFrameConversionsAcceptGeneratedJPEG(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	dir := t.TempDir()
	jpegPath := filepath.Join(dir, "waveform.jpg")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
		"color=c=black:s=640x360,drawbox=x=60:y=160:w=520:h=40:color=white:t=fill",
		"-frames:v", "1", jpegPath).CombinedOutput(); err != nil {
		t.Fatalf("generate waveform JPEG: %v: %s", err, output)
	}
	source := httptest.NewServer(http.FileServer(http.Dir(dir)))
	t.Cleanup(source.Close)
	for _, role := range []string{"poster", "thumbnail"} {
		for _, codec := range []string{"webp", "avif"} {
			t.Run(role+"_"+codec, func(t *testing.T) {
				outputPath := filepath.Join(t.TempDir(), "frame."+codec)
				request := encodeRequest{
					InputURL: source.URL + "/waveform.jpg", Operation: "frame",
					FrameRole: role, FrameCodec: codec,
				}
				if output, err := exec.Command(ffmpeg, ffmpegArgsForOutput(request, "cpu", outputPath)...).CombinedOutput(); err != nil {
					t.Fatalf("convert generated JPEG: %v: %s", err, output)
				}
				pixels, err := exec.Command(ffmpeg, "-v", "error", "-i", outputPath, "-frames:v", "1",
					"-vf", "scale=320:180", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1").Output()
				if err != nil || len(pixels) != 320*180*3 || pixels[(90*320+160)*3] < 200 {
					t.Fatalf("expected a decodable frame retaining the white waveform: %v (%d bytes)", err, len(pixels))
				}
			})
		}
	}
}

func TestCustomThumbnailsAcceptLargeJPEGAndPNG(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	dir := t.TempDir()
	source := httptest.NewServer(http.FileServer(http.Dir(dir)))
	t.Cleanup(source.Close)
	for _, inputCodec := range []string{"jpg", "png"} {
		inputPath := filepath.Join(dir, "upload."+inputCodec)
		if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
			"color=c=white:s=3000x3000", "-frames:v", "1", inputPath).CombinedOutput(); err != nil {
			t.Fatalf("generate large upload: %v: %s", err, output)
		}
		for _, codec := range []string{"jpg", "webp", "avif"} {
			t.Run(inputCodec+"_to_"+codec, func(t *testing.T) {
				outputPath := filepath.Join(t.TempDir(), "thumbnail."+codec)
				request := encodeRequest{
					InputURL: source.URL + "/upload." + inputCodec, Operation: "frame",
					FrameRole: "custom_thumbnail", FrameCodec: codec,
				}
				if output, err := exec.Command(ffmpeg, ffmpegArgsForOutput(request, "cpu", outputPath)...).CombinedOutput(); err != nil {
					t.Fatalf("convert uploaded image: %v: %s", err, output)
				}
				pixels, err := exec.Command(ffmpeg, "-v", "error", "-i", outputPath,
					"-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1").Output()
				if err != nil || len(pixels) != 1280*1280*3 || pixels[0] < 200 {
					t.Fatalf("expected a visible 1280x1280 thumbnail: %v (%d bytes)", err, len(pixels))
				}
			})
		}
	}
}

func TestImageInputsAreLimitedToFrameOperations(t *testing.T) {
	for _, operation := range []string{"video", "audio", "waveform", "storyboard", "segments"} {
		args := strings.Join(ffmpegBaseArgs(encodeRequest{Operation: operation}), " ")
		for _, demuxer := range []string{"jpeg_pipe", "png_pipe"} {
			if strings.Contains(args, demuxer) {
				t.Fatalf("%s must not be enabled for %s", demuxer, operation)
			}
		}
	}
}

func TestAVIFFrameUsesSeekableOutput(t *testing.T) {
	request := encodeRequest{
		InputURL: "https://example.com/input.webm", Operation: "frame",
		FrameRole: "thumbnail", FrameCodec: "avif",
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
	if !requiresSeekableFrameOutput(request) {
		t.Fatal("expected AVIF frame output to require a seekable destination")
	}

	args := ffmpegArgsForOutput(request, "cpu", "/var/tmp/frame.avif")
	if args[len(args)-1] != "/var/tmp/frame.avif" || slices.Contains(args, "pipe:1") {
		t.Fatalf("expected seekable AVIF output path: %v", args)
	}
	if !slices.Contains(args, "avif") || !slices.Contains(args, "libsvtav1") || !slices.Contains(args, "avif=1") {
		t.Fatalf("expected AVIF encoder and muxer: %v", args)
	}
}

func TestEncodeHandlerUsesSeekableWorkspaceForAVIF(t *testing.T) {
	tempDir := t.TempDir()
	ffmpegPath := filepath.Join(tempDir, "ffmpeg")
	ffmpegScript := `#!/bin/sh
for output_path do :; done
printf 'fake-avif-frame' > "$output_path"
printf 'progress=end\n' >&2
`
	if err := os.WriteFile(ffmpegPath, []byte(ffmpegScript), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tempDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	handler := encodeHandler(time.Second, "avif-test", "cpu", "", requestSlots(0), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/encode", strings.NewReader(`{
		"input_url":"https://example.com/input.mp4",
		"operation":"frame",
		"frame_role":"thumbnail",
		"frame_codec":"avif"
	}`))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
	if response.Body.String() != "fake-avif-frame" {
		t.Fatalf("unexpected AVIF response: %q", response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != "image/avif" {
		t.Fatalf("unexpected content type: %q", got)
	}
}

func TestPackageHLSBuildsAudioCommand(t *testing.T) {
	request := packageHLSRequest{
		InputURL: "https://example.com/audio.mp3", MediaKind: "audio", Channels: 2,
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}
	args := packageHLSArgs(request, "/tmp/hls")
	for _, expected := range []string{"0:a:0", "aac", "2", "temp_file"} {
		if !slices.Contains(args, expected) {
			t.Fatalf("expected audio HLS argument %q is missing: %v", expected, args)
		}
	}
	if slices.Contains(args, "0:v:0") {
		t.Fatalf("audio HLS should not map a video stream: %v", args)
	}
}

func TestFFmpegStreamsCompleteVideo(t *testing.T) {
	request := encodeRequest{
		InputURL: "https://example.com/input.webm", Width: 1920,
		VideoBitrate: "8M", AudioBitrate: "192k", Preset: "medium",
	}
	args := ffmpegArgs(request, "cpu")
	if slices.Contains(args, "-t") || slices.Contains(args, "-to") || slices.Contains(args, "-frames:v") {
		t.Fatalf("unexpected duration limit in ffmpeg arguments: %v", args)
	}
	if !slices.Contains(args, "frag_keyframe+empty_moov+default_base_moof") {
		t.Fatalf("streaming movflags are missing: %v", args)
	}
}

func TestFFmpegPerformanceIsReturnedAsTrailers(t *testing.T) {
	recent := &recentLog{}
	recent.setProgress(map[string]string{
		"frame":       "1500",
		"fps":         "164.52",
		"speed":       "5.48x",
		"out_time_ms": "50000000",
		"total_size":  "123456",
		"dup_frames":  "2",
		"drop_frames": "1",
	})

	response := httptest.NewRecorder()
	declareFFmpegTrailers(response)
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write([]byte("media"))
	setFFmpegTrailers(response, time.Now().Add(-10*time.Millisecond), recent)

	result := response.Result()
	if result.Trailer.Get("X-Mave-FFmpeg-Elapsed-Ms") == "" {
		t.Fatal("expected FFmpeg elapsed trailer")
	}
	for header, expected := range map[string]string{
		"X-Mave-FFmpeg-Frames":       "1500",
		"X-Mave-FFmpeg-Fps":          "164.52",
		"X-Mave-FFmpeg-Speed":        "5.48x",
		"X-Mave-FFmpeg-Out-Time-Ms":  "50000000",
		"X-Mave-FFmpeg-Output-Bytes": "123456",
		"X-Mave-FFmpeg-Dup-Frames":   "2",
		"X-Mave-FFmpeg-Drop-Frames":  "1",
	} {
		if got := result.Trailer.Get(header); got != expected {
			t.Fatalf("expected trailer %s=%s, got %q", header, expected, got)
		}
	}
}

func TestHLSPackagingCopiesVideoIntoIndependentFMP4Segments(t *testing.T) {
	args := hlsArgs("/tmp/encoded.mp4", "/tmp/hls")
	for _, expected := range []string{
		"/tmp/encoded.mp4", "0:v:0", "copy", "independent_segments+temp_file", "fmp4",
		"init.mp4", "/tmp/hls/segment_%03d.m4s", "/tmp/hls/playlist.m3u8",
	} {
		if !slices.Contains(args, expected) {
			t.Fatalf("expected HLS argument %q is missing: %v", expected, args)
		}
	}
	if slices.Contains(args, "libx264") || slices.Contains(args, "aac") {
		t.Fatalf("HLS packaging must remux rather than re-encode: %v", args)
	}
}

func TestRemoteHLSPackagingSendsStorageReferer(t *testing.T) {
	args := hlsArgsWithReferer(
		"https://storage.example/encoded.mp4",
		"/tmp/hls",
		"https://ffmpeg.storage.mave.invalid/token",
		"",
	)
	for _, expected := range []string{
		"-headers", "Referer: https://ffmpeg.storage.mave.invalid/token\r\n",
		"https://storage.example/encoded.mp4", "copy",
	} {
		if !slices.Contains(args, expected) {
			t.Fatalf("expected HLS argument %q is missing: %v", expected, args)
		}
	}
}

func TestRemoteHLSPackagingSendsBasicAuth(t *testing.T) {
	request := packageHLSRequest{
		InputURL: "https://video:p%40ssword@example.com/encoded.mp4",
	}
	if err := request.validate(); err != nil {
		t.Fatal(err)
	}

	args := packageHLSArgs(request, "/tmp/hls")
	expected := "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("video:p@ssword")) + "\r\n"
	if !slices.Contains(args, expected) {
		t.Fatalf("expected Basic auth HLS header in arguments: %v", args)
	}
	if slices.Contains(args, "https://video:p%40ssword@example.com/encoded.mp4") {
		t.Fatalf("HLS input URL must be sanitized: %v", args)
	}
}

func TestWriteHLSBundleProducesHLSOnlyStoredArchive(t *testing.T) {
	hlsDir := t.TempDir()
	files := map[string]string{
		"init.mp4":        "init",
		"segment_000.m4s": "segment",
		"playlist.m3u8":   "#EXTM3U\n",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(hlsDir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	response := httptest.NewRecorder()
	if err := writeHLSBundle(response, hlsDir); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK {
		t.Fatalf("expected success, got %d", response.Code)
	}
	if got := response.Header().Get("Content-Type"); got != "application/vnd.mave.hls-bundle+zip" {
		t.Fatalf("unexpected content type %q", got)
	}

	reader, err := zip.NewReader(bytes.NewReader(response.Body.Bytes()), int64(response.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	if len(reader.File) != len(files) {
		t.Fatalf("unexpected archive entries: %v", reader.File)
	}
	for _, entry := range reader.File {
		if entry.Method != zip.Store {
			t.Fatalf("entry %s must be stored for streaming extraction", entry.Name)
		}
		file, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(file)
		closeErr := file.Close()
		if err != nil || closeErr != nil {
			t.Fatalf("could not read %s: %v / %v", entry.Name, err, closeErr)
		}
		name := strings.TrimPrefix(entry.Name, "hls/")
		if string(body) != files[name] {
			t.Fatalf("unexpected body for %s", entry.Name)
		}
	}
}

func TestHLSFilesUploadDirectlyThroughScopedDestinations(t *testing.T) {
	hlsDir := t.TempDir()
	expectedBodies := map[string]string{
		"init.mp4":        "init",
		"playlist.m3u8":   "#EXTM3U\n",
		"segment_000.m4s": "segment",
	}
	for name, body := range expectedBodies {
		if err := os.WriteFile(filepath.Join(hlsDir, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(hlsDir, "segment_999.m4s.tmp"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}

	uploaded := make(chan hlsFile, len(expectedBodies))
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/callback" {
			if got := request.Header.Get("Authorization"); got != "Bearer scoped-token" {
				t.Errorf("unexpected callback authorization %q", got)
			}
			var payload hlsUploadRequest
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Errorf("decode callback request: %v", err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			targets := make([]hlsUploadTarget, 0, len(payload.Files))
			for _, file := range payload.Files {
				contentType := "video/mp4"
				if file.Name == "playlist.m3u8" {
					contentType = "application/vnd.apple.mpegurl"
				}
				targets = append(targets, hlsUploadTarget{
					Name: file.Name, Key: "embed/h264_sd_hls/" + file.Name,
					ContentType: contentType, SizeBytes: file.SizeBytes,
					Upload: hlsPutDestination{
						URL: server.URL + "/objects/" + file.Name,
						Headers: map[string]string{
							"content-type":   contentType,
							"content-length": fmt.Sprintf("%d", file.SizeBytes),
						},
					},
				})
			}
			writer.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(writer).Encode(hlsUploadResponse{Uploads: targets})
			return
		}

		name := strings.TrimPrefix(request.URL.Path, "/objects/")
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read uploaded object: %v", err)
			writer.WriteHeader(http.StatusInternalServerError)
			return
		}
		uploaded <- hlsFile{Name: name, SizeBytes: int64(len(body)), ContentType: string(body)}
		writer.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = server.Client()
	defer func() { http.DefaultClient = oldClient }()

	files, err := collectHLSFiles(hlsDir)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := collectPendingHLSSegments(hlsDir, map[string]hlsFile{})
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 || pending[0].Name != "segment_000.m4s" {
		t.Fatalf("expected only the finalized segment, got %v", pending)
	}
	response := httptest.NewRecorder()
	encoder := json.NewEncoder(response)
	metadataByName := make(map[string]hlsFile)
	uploadedBytes, err := uploadAndRemoveHLSFiles(
		context.Background(),
		hlsDir,
		server.URL+"/callback",
		"scoped-token",
		files,
		metadataByName,
		0,
		encoder,
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	metadata, err := uploadedHLSMetadata(metadataByName)
	if err != nil {
		t.Fatal(err)
	}
	if len(metadata) != len(expectedBodies) || uploadedBytes != int64(len("init")+len("#EXTM3U\n")+len("segment")) {
		t.Fatalf("unexpected upload metadata: %v / %d", metadata, uploadedBytes)
	}
	for name := range expectedBodies {
		if _, err := os.Stat(filepath.Join(hlsDir, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("expected uploaded file %s to be removed, got %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(hlsDir, "segment_999.m4s.tmp")); err != nil {
		t.Fatalf("expected in-progress temp segment to remain: %v", err)
	}

	for range expectedBodies {
		file := <-uploaded
		if file.ContentType != expectedBodies[file.Name] {
			t.Fatalf("unexpected body for %s: %q", file.Name, file.ContentType)
		}
	}
}

func TestPackageHLSHandlerUploadsFinalizedSegmentsBeforeFFmpegCompletes(t *testing.T) {
	ffmpegDir := t.TempDir()
	ffmpegPath := filepath.Join(ffmpegDir, "ffmpeg")
	ffmpegScript := `#!/bin/sh
for last do :; done
output_dir=$(dirname "$last")
printf segment > "$output_dir/segment_000.m4s.tmp"
mv "$output_dir/segment_000.m4s.tmp" "$output_dir/segment_000.m4s"
sleep 1
printf init > "$output_dir/init.mp4"
printf '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6.0,\nsegment_000.m4s\n#EXT-X-ENDLIST\n' > "$output_dir/playlist.m3u8"
`
	if err := os.WriteFile(ffmpegPath, []byte(ffmpegScript), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", ffmpegDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("BUNDLE_TEMP_DIR", t.TempDir())

	callbackBatches := make(chan []string, 4)
	uploaded := make(chan string, 4)
	var server *httptest.Server
	server = httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/callback" {
			var payload hlsUploadRequest
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Errorf("decode callback request: %v", err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			names := make([]string, 0, len(payload.Files))
			targets := make([]hlsUploadTarget, 0, len(payload.Files))
			for _, file := range payload.Files {
				names = append(names, file.Name)
				contentType := "video/mp4"
				if file.Name == "playlist.m3u8" {
					contentType = "application/vnd.apple.mpegurl"
				}
				targets = append(targets, hlsUploadTarget{
					Name: file.Name, Key: "embed/h264_sd_hls/" + file.Name,
					ContentType: contentType, SizeBytes: file.SizeBytes,
					Upload: hlsPutDestination{
						URL: server.URL + "/objects/" + file.Name,
						Headers: map[string]string{
							"content-type":   contentType,
							"content-length": fmt.Sprintf("%d", file.SizeBytes),
						},
					},
				})
			}
			callbackBatches <- names
			writer.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(writer).Encode(hlsUploadResponse{Uploads: targets})
			return
		}

		uploaded <- strings.TrimPrefix(request.URL.Path, "/objects/")
		writer.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	oldClient := http.DefaultClient
	http.DefaultClient = server.Client()
	defer func() { http.DefaultClient = oldClient }()
	t.Setenv("HLS_UPLOAD_CALLBACK_URL", server.URL+"/callback")

	handler := packageHLSHandler(5*time.Second, "cpu-test", "", requestSlots(1), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/package-hls", strings.NewReader(`{
		"input_url":"https://storage.example/encoded.mp4",
		"upload_token":"scoped-token"
	}`))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"status":"completed"`) {
		t.Fatalf("expected completed streaming response, got %d: %s", response.Code, response.Body.String())
	}
	firstBatch := <-callbackBatches
	if len(firstBatch) != 1 || firstBatch[0] != "segment_000.m4s" {
		t.Fatalf("expected finalized segment to upload first, got %v", firstBatch)
	}
	secondBatch := <-callbackBatches
	slices.Sort(secondBatch)
	if !slices.Equal(secondBatch, []string{"init.mp4", "playlist.m3u8"}) {
		t.Fatalf("expected control files to upload last, got %v", secondBatch)
	}

	uploadedNames := []string{<-uploaded, <-uploaded, <-uploaded}
	slices.Sort(uploadedNames)
	if !slices.Equal(uploadedNames, []string{"init.mp4", "playlist.m3u8", "segment_000.m4s"}) {
		t.Fatalf("unexpected uploaded files: %v", uploadedNames)
	}
}

func TestPackageHLSHandlerRequiresBearerToken(t *testing.T) {
	handler := packageHLSHandler(time.Second, "cpu-test", "secret-token", requestSlots(1), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/package-hls", strings.NewReader(`{"input_url":"https://example.com/input.mp4"}`))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d: %s", response.Code, response.Body.String())
	}
}

func TestSanitizedFFmpegDetailsRemovesInputURLAndBoundsOutput(t *testing.T) {
	inputURL := "https://storage.example.test/input.mp4?secret=signed"
	inputBasicAuth := "video:password"
	encodedBasicAuth := base64.StdEncoding.EncodeToString([]byte(inputBasicAuth))
	details := sanitizedFFmpegDetails(
		strings.Repeat("x", 2_100)+"\n"+inputURL+"\nAuthorization: Basic "+encodedBasicAuth,
		ffmpegSourceRedactions(inputURL, inputBasicAuth)...,
	)

	if strings.Contains(details, inputURL) {
		t.Fatal("expected input URL to be redacted")
	}
	if strings.Contains(details, encodedBasicAuth) {
		t.Fatal("expected Basic auth header to be redacted")
	}
	if !strings.Contains(details, "<input-url>") {
		t.Fatal("expected redaction marker")
	}
	if len(details) > 2_000 {
		t.Fatalf("expected bounded details, got %d bytes", len(details))
	}
}

func TestBundleWorkspaceDefaultsOutsideTmpfs(t *testing.T) {
	t.Setenv("BUNDLE_TEMP_DIR", "")
	if got := bundleTempDir(); got != "/var/tmp" {
		t.Fatalf("expected disk-backed bundle workspace, got %q", got)
	}

	t.Setenv("BUNDLE_TEMP_DIR", "/workspace")
	if got := bundleTempDir(); got != "/workspace" {
		t.Fatalf("expected configured bundle workspace, got %q", got)
	}
}

func TestEncodeHandlerExposesInstanceAndLeavesConcurrencyToPlatform(t *testing.T) {
	handler := encodeHandler(time.Second, "instance-test", "cpu", "", requestSlots(0), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/encode", strings.NewReader(`{
		"input_url":"https://example.com/input.webm",
		"width":319
	}`))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("expected validation response, got status %d: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get(instanceHeader); got != "instance-test" {
		t.Fatalf("expected instance header, got %q", got)
	}
	if strings.Contains(response.Body.String(), "busy") {
		t.Fatalf("handler should not perform local concurrency admission: %s", response.Body.String())
	}
}

func TestNVENCCodecArguments(t *testing.T) {
	for codec, encoder := range map[string]string{"h264": "h264_nvenc", "hevc": "hevc_nvenc", "av1": "av1_nvenc"} {
		request := encodeRequest{InputURL: "https://example.com/input.mp4", Codec: codec, Width: 1920, VideoBitrate: "8M", AudioBitrate: "192k", Preset: "slow"}
		if err := request.validate(); err != nil {
			t.Fatal(err)
		}
		args := ffmpegArgs(request, "nvenc")
		if !slices.Contains(args, encoder) || !slices.Contains(args, "p5") {
			t.Fatalf("expected %s/p5 for %s: %v", encoder, codec, args)
		}
	}
}

func TestCPUCodecArguments(t *testing.T) {
	for codec, expected := range map[string][]string{
		"h264": {"libx264", "slow"},
		"hevc": {"libx265", "slow"},
		"av1":  {"libsvtav1", "6"},
	} {
		request := encodeRequest{InputURL: "https://example.com/input.mp4", Codec: codec, Width: 1920, VideoBitrate: "8M", AudioBitrate: "192k", Preset: "slow", Tune: "grain"}
		if err := request.validate(); err != nil {
			t.Fatal(err)
		}
		args := ffmpegArgs(request, "cpu")
		for _, value := range expected {
			if !slices.Contains(args, value) {
				t.Fatalf("expected %q for %s: %v", value, codec, args)
			}
		}
		if codec == "av1" && slices.Contains(args, "-tune") {
			t.Fatalf("AV1 must not receive an x264/x265 tune: %v", args)
		}
	}
}

func TestEncodeHandlerRequiresBearerToken(t *testing.T) {
	handler := encodeHandler(time.Second, "gpu-test", "nvenc", "secret-token", requestSlots(4), newActivityTracker())
	request := httptest.NewRequest(http.MethodPost, "/encode", strings.NewReader(`{"input_url":"https://example.com/input.mp4"}`))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d: %s", response.Code, response.Body.String())
	}
}

func TestIdleHandlerRequiresNoActiveEncodeAndMinimumIdleTime(t *testing.T) {
	tracker := newActivityTracker()
	handler := idleHandler(tracker, "secret-token", time.Millisecond)

	finish, accepted := tracker.tryBegin()
	if !accepted {
		t.Fatal("expected activity to be accepted")
	}
	request := httptest.NewRequest(http.MethodGet, "/idle", nil)
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("expected busy while encode is active, got %d", response.Code)
	}

	finish()
	time.Sleep(2 * time.Millisecond)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected idle after encode completed, got %d", response.Code)
	}
}

func TestIdleHandlerRequiresBearerToken(t *testing.T) {
	handler := idleHandler(newActivityTracker(), "secret-token", time.Nanosecond)
	request := httptest.NewRequest(http.MethodGet, "/idle", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected unauthorized, got %d", response.Code)
	}
}

func TestNVENCHealthChecksEverySupportedEncoderAndCachesSuccess(t *testing.T) {
	var calls atomic.Int32
	readiness := newEncoderReadiness("nvenc", time.Minute, func(_ context.Context, executable string, args ...string) ([]byte, error) {
		call := calls.Add(1)
		if executable != ffmpegExecutable {
			t.Fatalf("unexpected readiness executable: %s", executable)
		}
		if call == 1 {
			if !slices.Equal(args, []string{"-version"}) {
				t.Fatalf("unexpected ffmpeg readiness command: %v", args)
			}
			return nil, nil
		}
		if !slices.Contains(args, "-frames:v") ||
			!slices.Contains(args, "color=size=256x256:rate=1") {
			t.Fatalf("unexpected readiness command: %s %v", executable, args)
		}
		return nil, nil
	})
	handler := healthHandler("gpu-ready", readiness, newActivityTracker())

	for range 2 {
		request := httptest.NewRequest(http.MethodGet, "/health", nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("expected healthy response, got %d: %s", response.Code, response.Body.String())
		}
	}

	if calls.Load() != 4 {
		t.Fatalf("expected one cached ffmpeg probe plus three encoder probes, got %d commands", calls.Load())
	}
}

func TestNVENCHealthReturnsUnavailableWithoutLeakingProbeDetails(t *testing.T) {
	readiness := newEncoderReadiness("nvenc", time.Minute, func(_ context.Context, _ string, args ...string) ([]byte, error) {
		if slices.Equal(args, []string{"-version"}) {
			return nil, nil
		}
		return []byte("driver detail that must remain private"), errors.New("probe failed")
	})
	handler := healthHandler("gpu-unavailable", readiness, newActivityTracker())
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected unavailable response, got %d: %s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "driver detail") {
		t.Fatalf("health response leaked probe details: %s", response.Body.String())
	}
}

func TestCPUHealthReturnsUnavailableWhenFFmpegCannotStart(t *testing.T) {
	readiness := newEncoderReadiness("cpu", time.Minute, func(_ context.Context, executable string, args ...string) ([]byte, error) {
		if executable != ffmpegExecutable || !slices.Equal(args, []string{"-version"}) {
			t.Fatalf("unexpected readiness command: %s %v", executable, args)
		}
		return nil, exec.ErrNotFound
	})
	response := httptest.NewRecorder()
	healthHandler("cpu-unavailable", readiness, newActivityTracker()).ServeHTTP(
		response,
		httptest.NewRequest(http.MethodGet, "/health", nil),
	)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected unavailable response, got %d: %s", response.Code, response.Body.String())
	}
}

func TestHealthDoesNotProbeFFmpegDuringActiveEncode(t *testing.T) {
	var calls atomic.Int32
	readiness := newEncoderReadiness("cpu", time.Minute, func(_ context.Context, _ string, _ ...string) ([]byte, error) {
		calls.Add(1)
		return nil, exec.ErrNotFound
	})
	tracker := newActivityTracker()
	finish, accepted := tracker.tryBegin()
	if !accepted {
		t.Fatal("expected activity to be accepted")
	}
	defer finish()

	response := httptest.NewRecorder()
	healthHandler("cpu-busy", readiness, tracker).ServeHTTP(
		response,
		httptest.NewRequest(http.MethodGet, "/health", nil),
	)

	if response.Code != http.StatusOK {
		t.Fatalf("expected active encoder to remain healthy, got %d: %s", response.Code, response.Body.String())
	}
	if calls.Load() != 0 {
		t.Fatalf("expected no FFmpeg readiness probe during active encode, got %d", calls.Load())
	}
}

func TestHealthWarmupHoldKeepsRequestOpenForScaleOut(t *testing.T) {
	readiness := newEncoderReadiness("cpu", time.Minute, func(_ context.Context, _ string, _ ...string) ([]byte, error) {
		return nil, nil
	})
	request := httptest.NewRequest(http.MethodGet, "/warmup?hold_ms=25", nil)
	response := httptest.NewRecorder()
	startedAt := time.Now()

	healthHandler("cpu-warmup", readiness, newActivityTracker()).ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected healthy response, got %d: %s", response.Code, response.Body.String())
	}
	if elapsed := time.Since(startedAt); elapsed < 20*time.Millisecond {
		t.Fatalf("expected warmup request to remain open, completed after %s", elapsed)
	}
}

func TestDrainPreventsNewEncodesUntilResumed(t *testing.T) {
	tracker := newActivityTracker()
	time.Sleep(2 * time.Millisecond)
	drain := drainHandler(tracker, "secret-token", time.Millisecond)
	request := httptest.NewRequest(http.MethodPost, "/drain", nil)
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()
	drain.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("expected drain to succeed, got %d: %s", response.Code, response.Body.String())
	}

	if finish, accepted := tracker.tryBegin(); accepted {
		finish()
		t.Fatal("draining tracker accepted a new encode")
	}

	readiness := newEncoderReadiness("cpu", time.Minute, func(_ context.Context, _ string, _ ...string) ([]byte, error) {
		return nil, nil
	})
	health := httptest.NewRecorder()
	healthHandler("draining", readiness, tracker).ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/health", nil))
	if health.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected draining instance to be unhealthy, got %d", health.Code)
	}

	resume := resumeHandler(tracker, "secret-token")
	resumeResponse := httptest.NewRecorder()
	resume.ServeHTTP(resumeResponse, request)
	if resumeResponse.Code != http.StatusOK {
		t.Fatalf("expected resume to succeed, got %d", resumeResponse.Code)
	}
	if finish, accepted := tracker.tryBegin(); !accepted {
		t.Fatal("resumed tracker rejected a new encode")
	} else {
		finish()
	}
}

func TestDrainRefusesWhileEncodeIsActive(t *testing.T) {
	tracker := newActivityTracker()
	finish, accepted := tracker.tryBegin()
	if !accepted {
		t.Fatal("expected activity to be accepted")
	}
	defer finish()

	handler := drainHandler(tracker, "secret-token", 0)
	request := httptest.NewRequest(http.MethodPost, "/drain", nil)
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusConflict {
		t.Fatalf("expected active encode to block draining, got %d", response.Code)
	}
}

func TestAudioPeaksValidation(t *testing.T) {
	for _, duration := range []float64{0, -1, 86401, math.NaN(), math.Inf(1)} {
		r := encodeRequest{InputURL: "https://example.com/audio.mp3", Operation: "audio_peaks", DurationSeconds: duration}
		if r.validate() == nil {
			t.Fatalf("accepted invalid duration %v", duration)
		}
	}
	r := encodeRequest{InputURL: "https://example.com/audio.mp3", Operation: "audio_peaks", DurationSeconds: 86400}
	if err := r.validate(); err != nil {
		t.Fatal(err)
	}
	r.PackageHLS = true
	if r.validate() == nil {
		t.Fatal("accepted HLS for metadata")
	}
}

func TestAudioPeaksPreservesSilenceAndOppositePhaseStereo(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg is not installed")
	}
	source := filepath.Join(t.TempDir(), "audio.wav")
	if output, err := exec.Command(ffmpeg, "-v", "error", "-f", "lavfi", "-i",
		"aevalsrc='if(lt(t,1),0,0.5*sin(2*PI*440*t))|-if(lt(t,1),0,0.5*sin(2*PI*440*t))':s=48000:d=2",
		"-c:a", "pcm_s16le", source).CombinedOutput(); err != nil {
		t.Fatalf("generate: %v: %s", err, output)
	}
	command := exec.Command(ffmpeg, audioPeaksFFmpegArgs(encodeRequest{InputURL: source, DurationSeconds: 2})...)
	var stderr bytes.Buffer
	command.Stderr = &stderr
	body, err := command.Output()
	if err != nil {
		t.Fatalf("peaks: %v: %s", err, stderr.String())
	}
	var peaks []string
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "lavfi.astats.Overall.Peak_level=") {
			peaks = append(peaks, strings.TrimPrefix(line, "lavfi.astats.Overall.Peak_level="))
		}
	}
	if len(peaks) < 510 || len(peaks) > 512 {
		t.Fatalf("unexpected bucket count %d", len(peaks))
	}
	for _, peak := range peaks[:250] {
		if peak != "-inf" {
			t.Fatalf("silence: %s", peak)
		}
	}
	for _, peak := range peaks[260:] {
		if !strings.HasPrefix(peak, "-6.02") {
			t.Fatalf("opposite-phase peak: %s", peak)
		}
	}
}

func TestAudioPeaksHandlerDoesNotPublishPartialOutput(t *testing.T) {
	for _, exit := range []string{"0", "1"} {
		t.Run(exit, func(t *testing.T) {
			dir := t.TempDir()
			script := "#!/bin/sh\nprintf 'lavfi.astats.Overall.Peak_level=-20\n'\nexit " + exit + "\n"
			if err := os.WriteFile(filepath.Join(dir, "ffmpeg"), []byte(script), 0700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
			recorder := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodPost, "/encode", strings.NewReader(`{"input_url":"https://example.com/audio.mp3","operation":"audio_peaks","duration_seconds":2}`))
			encodeHandler(time.Second, "test", "cpu", "", nil, newActivityTracker())(recorder, request)
			if exit == "0" {
				if recorder.Code != 200 || !strings.HasPrefix(recorder.Header().Get("Content-Type"), "text/plain") {
					t.Fatalf("unexpected response: %d %s", recorder.Code, recorder.Body.String())
				}
			} else if recorder.Code != 502 || strings.Contains(recorder.Body.String(), "Peak_level") {
				t.Fatalf("published partial output: %d %s", recorder.Code, recorder.Body.String())
			}
		})
	}
}
