package main

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

func startTestBroker(t *testing.T, limit int) (*net.UnixConn, context.CancelFunc) {
	t.Helper()
	parent, child, err := socketPair(syscall.SOCK_SEQPACKET)
	if err != nil {
		t.Fatal(err)
	}
	server, err := net.FileConn(parent)
	parent.Close()
	if err != nil {
		child.Close()
		t.Fatal(err)
	}
	client, err := net.FileConn(child)
	child.Close()
	if err != nil {
		server.Close()
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		serveWithConnectionLimit(ctx, server.(*net.UnixConn), newBroker(), limit)
	}()
	t.Cleanup(func() {
		cancel()
		client.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("broker did not stop")
		}
	})
	return client.(*net.UnixConn), cancel
}

func brokerConnection(t *testing.T, control *net.UnixConn) net.Conn {
	t.Helper()
	control.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := control.Write([]byte{'C'}); err != nil {
		t.Fatal(err)
	}
	var reply [1]byte
	oob := make([]byte, syscall.CmsgSpace(4))
	_, count, _, _, err := control.ReadMsgUnix(reply[:], oob)
	if err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		if reply[0] != 'N' {
			t.Fatalf("unexpected refusal: %q", reply)
		}
		return nil
	}
	messages, err := syscall.ParseSocketControlMessage(oob[:count])
	if err != nil || len(messages) != 1 {
		t.Fatalf("invalid descriptors: %v", err)
	}
	fds, err := syscall.ParseUnixRights(&messages[0])
	if err != nil || len(fds) != 1 {
		t.Fatalf("invalid rights: %v", err)
	}
	file := os.NewFile(uintptr(fds[0]), "parser-connection")
	connection, err := net.FileConn(file)
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	connection.SetDeadline(time.Now().Add(5 * time.Second))
	return connection
}

func TestBrokerAllowsMoreThanLifetimeBudgetOfSequentialConnections(t *testing.T) {
	control, _ := startTestBroker(t, maxActiveConnections)
	for i := 0; i < maxActiveConnections+100; i++ {
		connection := brokerConnection(t, control)
		if connection == nil {
			t.Fatalf("connection %d refused", i+1)
		}
		// Invalid sources are rejected locally, without any outbound requests.
		_, err := io.WriteString(connection, "GET /0 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
		if err != nil {
			t.Fatal(err)
		}
		response, err := io.ReadAll(connection)
		connection.Close()
		if err != nil || !strings.Contains(string(response), "403 Forbidden") {
			t.Fatalf("request %d failed: %v", i+1, err)
		}
	}
}

func TestBrokerBoundsLiveConnectionsAndReusesClosedSlots(t *testing.T) {
	control, _ := startTestBroker(t, 2)
	first := brokerConnection(t, control)
	second := brokerConnection(t, control)
	if first == nil || second == nil {
		t.Fatal("initial connections refused")
	}
	defer second.Close()
	if excess := brokerConnection(t, control); excess != nil {
		excess.Close()
		t.Fatal("exceeded live connection limit")
	}
	first.Close()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if replacement := brokerConnection(t, control); replacement != nil {
			replacement.Close()
			return
		}
	}
	t.Fatal("closed connection slot was not released")
}

func TestBrokerCancellationClosesLiveConnections(t *testing.T) {
	control, cancel := startTestBroker(t, 2)
	connection := brokerConnection(t, control)
	if connection == nil {
		t.Fatal("connection refused")
	}
	defer connection.Close()
	// Get a response first to ensure the HTTP server has accepted the socket.
	io.WriteString(connection, "GET /0 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
	response, err := http.ReadResponse(bufio.NewReader(connection), nil)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	cancel()
	var data [1]byte
	_, err = connection.Read(data[:])
	if err != io.EOF {
		t.Fatalf("expected closed connection, got %v", err)
	}
}

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
