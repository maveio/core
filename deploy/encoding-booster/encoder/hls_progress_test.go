package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestHLSHeartbeatContinuesWithoutFilesAndStopsAfterCompletion(t *testing.T) {
	response := newSynchronizedResponseRecorder()
	progress := newHLSProgress(response, response)
	if err := progress.send(hlsUploadEvent{Status: "packaging"}); err != nil {
		t.Fatal(err)
	}
	<-response.flushes
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stop := progress.keepAlive(ctx, time.Millisecond, cancel)
	defer stop()
	select {
	case <-response.flushes:
	case <-time.After(time.Second):
		t.Fatal("no heartbeat while waiting for the first segment")
	}
	if err := progress.send(hlsUploadEvent{Status: "uploading", UploadedBytes: 42, FileCount: 1}); err != nil {
		t.Fatal(err)
	}
	if err := progress.heartbeat(); err != nil {
		t.Fatal(err)
	}
	if err := progress.send(hlsUploadEvent{Status: "completed", UploadedBytes: 42, FileCount: 1}); err != nil {
		t.Fatal(err)
	}
	if err := progress.heartbeat(); err != nil {
		t.Fatal(err)
	}
	stop()
	lines := strings.Split(strings.TrimSpace(response.bodyString()), "\n")
	for index, line := range lines {
		var event hlsUploadEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("concurrent writers corrupted an event: %v", err)
		}
		if index == len(lines)-1 && event.Status != "completed" {
			t.Fatalf("completion must be the final event: %s", line)
		}
		if event.Status == "uploading" && (event.UploadedBytes != 42 || event.FileCount != 1) {
			t.Fatalf("heartbeat lost the latest progress: %s", line)
		}
	}
}

type failingHLSWriter struct{}

func (failingHLSWriter) Write([]byte) (int, error) {
	return 0, errors.New("disconnected")
}

func TestHLSHeartbeatCancelsWorkWhenClientDisconnects(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	progress := newHLSProgress(failingHLSWriter{}, nil)
	progress.latest = hlsUploadEvent{Status: "packaging"}
	stop := progress.keepAlive(ctx, time.Millisecond, cancel)
	defer stop()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("encoder work was not canceled after the response failed")
	}
}
