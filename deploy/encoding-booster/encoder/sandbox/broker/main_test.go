package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBrokerScopesCredentialsAndRanges(t *testing.T) {
	requests := 0
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path != "/authorized" || r.Header.Get("Authorization") != "Bearer private" || r.Header.Get("Range") != "bytes=2-4" {
			t.Errorf("incorrect trusted request: path=%s range=%s", r.URL.Path, r.Header.Get("Range"))
		}
		if r.Header.Get("Cookie") != "" {
			t.Error("forwarded parser headers")
		}
		w.Header().Set("Content-Range", "bytes 2-4/6")
		w.Header().Set("Set-Cookie", "secret")
		w.WriteHeader(206)
		_, _ = io.WriteString(w, "cde")
	}))
	defer origin.Close()
	b := newBroker()
	_, err := b.add(origin.URL+"/authorized", http.Header{"Authorization": {"Bearer private"}})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("GET", "/0", nil)
	r.Host = "127.0.0.1"
	r.Header.Set("Range", "bytes=2-4")
	r.Header.Set("Cookie", "attacker")
	w := httptest.NewRecorder()
	b.ServeHTTP(w, r)
	if w.Code != 206 || w.Body.String() != "cde" || w.Header().Get("Set-Cookie") != "" {
		t.Fatal("range response not isolated")
	}
	for _, target := range []string{"/1", "/00", "/0?url=http://internal/", "http://internal/0", "/../0"} {
		r := httptest.NewRequest("GET", target, nil)
		r.Host = "127.0.0.1"
		w := httptest.NewRecorder()
		b.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Errorf("accepted %s", target)
		}
	}
	if requests != 1 {
		t.Fatal("unauthorized upstream request")
	}
}

func TestBrokerDoesNotFollowRedirectOrExposeErrorBody(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "http://internal.invalid/secret")
		w.WriteHeader(302)
		_, _ = io.WriteString(w, "sensitive upstream details")
	}))
	defer origin.Close()
	b := newBroker()
	_, _ = b.add(origin.URL, make(http.Header))
	r := httptest.NewRequest("GET", "/0", nil)
	r.Host = "127.0.0.1"
	w := httptest.NewRecorder()
	b.ServeHTTP(w, r)
	if w.Code != 502 || w.Header().Get("Location") != "" || strings.Contains(w.Body.String(), "sensitive") {
		t.Fatal("redirect escaped broker")
	}
}

func TestPrepareKeepsSecretsOutOfParserArgumentsAndConcat(t *testing.T) {
	b := newBroker()
	args, input, err := b.prepare([]string{"-headers", "Referer: private\r\n", "-i", "https://storage/input?signature=secret", "-f", "concat", "-i", "pipe:0", "pipe:1"}, strings.NewReader("file 'https://storage/part?signature=secret'\n"), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "private") || strings.Contains(joined, "secret") || strings.Contains(joined, "storage") || !strings.Contains(joined, "http://127.0.0.1/0") {
		t.Fatal("parser received source authority")
	}
	if len(b.sources) != 2 || b.sources[0].Headers.Get("Referer") != "private" || b.sources[1].Headers.Get("Referer") != "" {
		t.Fatal("incorrect input credential scope")
	}
	body, _ := io.ReadAll(input)
	if len(body) != 0 {
		t.Fatal("original manifest forwarded")
	}
	if _, err := b.manifest([]byte("option protocol_whitelist ALL\n"), nil); err == nil {
		t.Fatal("accepted unknown concat directive")
	}
}

func TestProxyRejectsMutationAndHeaderInjection(t *testing.T) {
	b := newBroker()
	_, _ = b.add("http://never.invalid/", nil)
	for _, method := range []string{"POST", "PUT", "CONNECT", "DELETE"} {
		r := httptest.NewRequest(method, "/0", nil)
		r.Host = "127.0.0.1"
		w := httptest.NewRecorder()
		b.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatal("accepted mutation")
		}
	}
	if _, err := parseHeaders("Authorization: private\nInjected: value\r\n"); err == nil {
		t.Fatal("accepted injected header")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := httptest.NewRequest("GET", "/0", nil).WithContext(ctx)
	r.Host = "127.0.0.1"
	r.Header.Set("Range", "bytes=0-1,3-4")
	w := httptest.NewRecorder()
	b.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal("accepted arbitrary range")
	}
}

func TestConcatPreservesEscapedSourceNames(t *testing.T) {
	b := newBroker()
	body, err := b.manifest([]byte("ffconcat version 1.0\nfile 'https://storage/a'\\''b.mp4'\n"), nil)
	if err != nil || !strings.Contains(string(body), "http://127.0.0.1/0") || len(b.sources) != 1 || b.sources[0].URL != "https://storage/a'b.mp4" {
		t.Fatal("escaped source name was not preserved")
	}
}
