package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type deferredBodyTransport struct {
	bodies []io.ReadCloser
}

func (transport *deferredBodyTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	// A RoundTripper may finish reading/closing the request body after returning
	// a response. Keep it live until the uploader has moved on to later parts.
	transport.bodies = append(transport.bodies, request.Body)
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Etag": []string{`"part"`}},
		Body:       http.NoBody,
		Request:    request,
	}, nil
}

func TestMultipartPartsRemainIntactUntilTransportClosesTheirBodies(t *testing.T) {
	transport := &deferredBodyTransport{}
	previous := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: transport}
	t.Cleanup(func() {
		http.DefaultClient = previous
		for _, body := range transport.bodies {
			_ = body.Close()
		}
	})

	upload := multipartUpload{
		PartSizeBytes: 8,
		PartURLs: []string{
			"https://storage.example/object?partNumber=1",
			"https://storage.example/object?partNumber=2",
			"https://storage.example/object?partNumber=3",
		},
	}
	const data = "abcdefghIJKLMNOPqrst"
	size, parts, err := streamToMultipartUpload(context.Background(), httptest.NewRecorder(), strings.NewReader(data), upload)
	if err != nil || size != int64(len(data)) || len(parts) != 3 {
		t.Fatalf("upload failed: bytes=%d parts=%d err=%v", size, len(parts), err)
	}
	var stored strings.Builder
	for _, body := range transport.bodies {
		if _, err := io.Copy(&stored, body); err != nil {
			t.Fatal(err)
		}
	}
	if stored.String() != data {
		t.Fatalf("multipart data changed before transport released it: got %q, want %q", stored.String(), data)
	}
}
