package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestMediaOutputRejectsLinksAndSpecialFiles(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "private")
	if err := os.WriteFile(private, []byte("private-marker"), 0600); err != nil {
		t.Fatal(err)
	}
	job := filepath.Join(root, "job")
	if err := os.Mkdir(job, 0700); err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"symlink", "hardlink", "fifo", "directory", "ancestor"} {
		t.Run(kind, func(t *testing.T) {
			path := filepath.Join(job, kind)
			var err error
			switch kind {
			case "symlink":
				err = os.Symlink(private, path)
			case "hardlink":
				err = os.Link(private, path)
			case "fifo":
				err = syscall.Mkfifo(path, 0600)
			case "directory":
				err = os.Mkdir(path, 0700)
			case "ancestor":
				err = os.Symlink(root, path)
				path = filepath.Join(path, "private")
			}
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() {
				f, err := openMediaOutput(path)
				if f != nil {
					f.Close()
				}
				done <- err
			}()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("accepted unsafe output")
				}
			case <-time.After(time.Second):
				t.Fatal("blocked opening special output")
			}
		})
	}
}

func TestHLSControlAndArchiveRejectSymlinkOutput(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "private")
	if err := os.WriteFile(private, []byte("private-marker"), 0600); err != nil {
		t.Fatal(err)
	}
	job := filepath.Join(root, "job")
	if err := os.Mkdir(job, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(private, filepath.Join(job, "init.mp4")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(job, "playlist.m3u8"), []byte("#EXTM3U\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := collectHLSControlFiles(job); err == nil {
		t.Fatal("accepted linked control file")
	}
	var body bytes.Buffer
	writer := zip.NewWriter(&body)
	if err := writeHLSZipEntry(writer, job, "init.mp4", make([]byte, 1024)); err == nil {
		t.Fatal("archived linked output")
	}
	writer.Close()
	if bytes.Contains(body.Bytes(), []byte("private-marker")) {
		t.Fatal("private contents escaped")
	}
}

func TestHLSUploadRejectsReplacementAfterCollection(t *testing.T) {
	for _, ancestor := range []bool{false, true} {
		t.Run(map[bool]string{false: "leaf", true: "ancestor"}[ancestor], func(t *testing.T) {
			root := t.TempDir()
			job, other := filepath.Join(root, "job"), filepath.Join(root, "other")
			for _, dir := range []string{job, other} {
				if err := os.Mkdir(dir, 0700); err != nil {
					t.Fatal(err)
				}
			}
			name := "segment_000.m4s"
			for dir, body := range map[string]string{job: "public", other: "secret"} {
				if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
					t.Fatal(err)
				}
			}
			files, err := collectPendingHLSSegments(job, map[string]hlsFile{})
			if err != nil {
				t.Fatal(err)
			}
			var puts atomic.Int32
			var server *httptest.Server
			server = httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/callback" {
					puts.Add(1)
					w.WriteHeader(200)
					return
				}
				var err error
				if ancestor {
					err = os.Rename(job, job+"-old")
					if err == nil {
						err = os.Symlink(other, job)
					}
				} else {
					err = os.Remove(filepath.Join(job, name))
					if err == nil {
						err = os.Symlink(filepath.Join(other, name), filepath.Join(job, name))
					}
				}
				if err != nil {
					t.Error(err)
					w.WriteHeader(500)
					return
				}
				json.NewEncoder(w).Encode(hlsUploadResponse{Uploads: []hlsUploadTarget{{Name: name, Key: name, ContentType: "video/iso.segment", SizeBytes: 6, Upload: hlsPutDestination{URL: server.URL + "/object"}}}})
			}))
			defer server.Close()
			old := http.DefaultClient
			http.DefaultClient = server.Client()
			defer func() { http.DefaultClient = old }()
			_, err = uploadAndRemoveHLSFiles(context.Background(), job, server.URL+"/callback", "test", files, map[string]hlsFile{}, 0, json.NewEncoder(io.Discard), nil)
			if err == nil || err.Error() != "could not open HLS output" {
				t.Fatalf("expected output rejection, got %v", err)
			}
			if puts.Load() != 0 {
				t.Fatal("unsafe output reached upload")
			}
		})
	}
}

func TestHLSUploadRetryKeepsVerifiedFile(t *testing.T) {
	root := t.TempDir()
	path, private := filepath.Join(root, "segment_000.m4s"), filepath.Join(root, "private")
	for p, body := range map[string]string{path: "public", private: "secret"} {
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	var calls atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil || string(body) != "public" {
			t.Errorf("unverified retry contents: %q / %v", body, err)
		}
		if calls.Add(1) == 1 {
			if err := os.Remove(path); err != nil {
				t.Error(err)
			}
			if err := os.Symlink(private, path); err != nil {
				t.Error(err)
			}
			w.WriteHeader(503)
			return
		}
		w.WriteHeader(200)
	}))
	defer server.Close()
	old := http.DefaultClient
	http.DefaultClient = server.Client()
	defer func() { http.DefaultClient = old }()
	if err := uploadHLSFile(context.Background(), path, hlsUploadTarget{SizeBytes: 6, Upload: hlsPutDestination{URL: server.URL}}); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("expected retry, got %d", calls.Load())
	}
}
