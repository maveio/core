package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestBrokerRetriesTransientReadsWithOriginalScope(t *testing.T) {
	for _, failure := range []string{"503", "transport"} {
		t.Run(failure, func(t *testing.T) {
			var reads atomic.Int32
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "GET" || r.Header.Get("Range") != "bytes=2-4" || r.Header.Get("Authorization") != "Bearer scoped" || r.Header.Get("Cookie") != "" {
					t.Error("retry changed the authorized request")
				}
				if reads.Add(1) < 3 {
					if failure == "transport" {
						connection, _, _ := w.(http.Hijacker).Hijack()
						connection.Close()
					} else {
						w.WriteHeader(503)
						io.WriteString(w, "private upstream body")
					}
					return
				}
				w.Header().Set("Content-Range", "bytes 2-4/6")
				w.WriteHeader(206)
				io.WriteString(w, "cde")
			}))
			defer origin.Close()
			b := newBroker()
			b.add(origin.URL, http.Header{"Authorization": {"Bearer scoped"}})
			r := httptest.NewRequest("GET", "/0", nil)
			r.Host = "127.0.0.1"
			r.Header.Set("Range", "bytes=2-4")
			r.Header.Set("Cookie", "untrusted")
			w := httptest.NewRecorder()
			b.ServeHTTP(w, r)
			if w.Code != 206 || w.Body.String() != "cde" || reads.Load() != 3 {
				t.Fatalf("transient read did not recover: status=%d reads=%d", w.Code, reads.Load())
			}
		})
	}
}

func TestBrokerKeepsTerminalStatusAndBoundsTransientRetries(t *testing.T) {
	for _, status := range []int{400, 401, 403, 404, 410, 503} {
		var reads atomic.Int32
		origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			reads.Add(1)
			w.Header().Set("Location", "https://private.invalid/secret")
			w.WriteHeader(status)
			io.WriteString(w, "private upstream body")
		}))
		b := newBroker()
		b.add(origin.URL, nil)
		r := httptest.NewRequest("HEAD", "/0", nil)
		r.Host = "127.0.0.1"
		w := httptest.NewRecorder()
		b.ServeHTTP(w, r)
		expected := int32(1)
		if status == 503 {
			expected = 3
		}
		if w.Code != status || reads.Load() != expected || strings.Contains(w.Body.String(), "private") || w.Header().Get("Location") != "" {
			t.Errorf("unsafe status/retry behavior: upstream=%d returned=%d reads=%d", status, w.Code, reads.Load())
		}
		origin.Close()
	}
}

func TestBrokerStopsRetryingWhenParserCancels(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var reads atomic.Int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.Add(1)
		cancel()
		w.WriteHeader(503)
	}))
	defer origin.Close()
	b := newBroker()
	b.add(origin.URL, nil)
	r := httptest.NewRequest("GET", "/0", nil).WithContext(ctx)
	r.Host = "127.0.0.1"
	b.ServeHTTP(httptest.NewRecorder(), r)
	if reads.Load() != 1 {
		t.Fatalf("continued after cancellation: %d", reads.Load())
	}
}
