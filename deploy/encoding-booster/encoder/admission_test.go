package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHeavyRoutesShareAdmissionAndReleaseAfterDrain(t *testing.T) {
	slots := requestSlots(1)
	tracker := newActivityTracker()
	upload := multipartUpload{
		PartSizeBytes: 5 * 1024 * 1024,
		PartURLs:      []string{"https://storage.example/object?partNumber=1&uploadId=test"},
		CompleteURL:   "https://storage.example/object?uploadId=test",
		AbortURL:      "https://storage.example/object?uploadId=test",
	}
	routes := []struct {
		name    string
		handler http.HandlerFunc
		payload any
	}{
		{"encode", encodeHandler(time.Second, "test", "cpu", "secret", slots, tracker), encodeRequest{InputURL: "https://storage.example/video.mp4"}},
		{"concat", concatHandler(time.Second, "test", "secret", slots, tracker), concatRequest{InputURLs: []string{"https://storage.example/a.mp4", "https://storage.example/b.mp4"}, OutputUpload: upload}},
		{"transfer", transferHandler(time.Second, "test", "secret", slots, tracker), transferRequest{InputURL: "https://storage.example/video.mp4", OutputUpload: upload}},
		{"package-hls", packageHLSHandler(time.Second, "test", "secret", slots, tracker), packageHLSRequest{InputURL: "https://storage.example/video.mp4"}},
	}

	slots <- struct{}{}
	for _, route := range routes {
		t.Run(route.name, func(t *testing.T) {
			body, err := json.Marshal(route.payload)
			if err != nil {
				t.Fatal(err)
			}
			for _, authorized := range []bool{false, true} {
				request := httptest.NewRequest(http.MethodPost, "/"+route.name, bytes.NewReader(body))
				if authorized {
					request.Header.Set("Authorization", "Bearer secret")
				}
				response := httptest.NewRecorder()
				route.handler(response, request)
				expected := http.StatusUnauthorized
				if authorized {
					expected = http.StatusTooManyRequests
				}
				if response.Code != expected {
					t.Fatalf("got %d: %s", response.Code, response.Body.String())
				}
			}
		})
	}
	<-slots
	tracker.draining = true
	for _, route := range routes {
		body, _ := json.Marshal(route.payload)
		request := httptest.NewRequest(http.MethodPost, "/"+route.name, bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer secret")
		response := httptest.NewRecorder()
		route.handler(response, request)
		if response.Code != http.StatusServiceUnavailable || len(slots) != 0 {
			t.Fatalf("%s leaked admission while draining: %d %s", route.name, response.Code, response.Body.String())
		}
	}
	if requestSlots(0) != nil || requestSlots(-1) != nil {
		t.Fatal("unlimited admission must remain disabled")
	}
}

func TestActiveTransferBlocksEncodeAndReleasesOnFailure(t *testing.T) {
	slots := requestSlots(1)
	tracker := newActivityTracker()
	started := make(chan struct{})
	release := make(chan struct{})
	previous := performSourceRequest
	performSourceRequest = func(request *http.Request) (*http.Response, error) {
		close(started)
		<-release
		return nil, errors.New("controlled source failure")
	}
	defer func() { performSourceRequest = previous }()
	body, _ := json.Marshal(transferRequest{
		InputURL:     "https://storage.example/video.mp4",
		OutputUpload: multipartUpload{PartSizeBytes: 5 * 1024 * 1024, PartURLs: []string{"https://storage.example/object?partNumber=1&uploadId=test"}, CompleteURL: "https://storage.example/object?uploadId=test", AbortURL: "https://storage.example/object?uploadId=test"},
	})
	done := make(chan struct{})
	go func() {
		defer close(done)
		transferHandler(time.Second, "test", "", slots, tracker)(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/transfer", bytes.NewReader(body)))
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		close(release)
		<-done
		t.Fatal("transfer did not start")
	}
	request := httptest.NewRequest(http.MethodPost, "/encode", bytes.NewBufferString(`{"input_url":"https://storage.example/video.mp4"}`))
	response := httptest.NewRecorder()
	encodeHandler(time.Second, "test", "cpu", "", slots, tracker)(response, request)
	close(release)
	<-done
	if response.Code != http.StatusTooManyRequests || len(slots) != 0 {
		t.Fatalf("cross-route admission failed: status=%d slots=%d", response.Code, len(slots))
	}
}
