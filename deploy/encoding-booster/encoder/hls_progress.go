package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sync"
	"time"
)

// One writer serializes progress and heartbeats, including during a slow
// authorization or object upload. Completion is always the final event.
type hlsProgress struct {
	mu       sync.Mutex
	encoder  *json.Encoder
	flusher  http.Flusher
	latest   hlsUploadEvent
	finished bool
	err      error
}

func newHLSProgress(writer io.Writer, flusher http.Flusher) *hlsProgress {
	return &hlsProgress{encoder: json.NewEncoder(writer), flusher: flusher}
}

func (progress *hlsProgress) send(event hlsUploadEvent) error {
	progress.mu.Lock()
	defer progress.mu.Unlock()
	return progress.sendLocked(event)
}

func (progress *hlsProgress) sendLocked(event hlsUploadEvent) error {
	if progress.finished {
		return progress.err
	}
	progress.latest = event
	progress.err = progress.encoder.Encode(event)
	if progress.err == nil && progress.flusher != nil {
		progress.flusher.Flush()
	}
	progress.finished = progress.err != nil || event.Status == "completed" || event.Status == "failed"
	return progress.err
}

func (progress *hlsProgress) heartbeat() error {
	progress.mu.Lock()
	defer progress.mu.Unlock()
	if progress.latest.Status == "" {
		return nil
	}
	return progress.sendLocked(progress.latest)
}

func (progress *hlsProgress) keepAlive(ctx context.Context, interval time.Duration, cancelWork context.CancelFunc) func() {
	ctx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if progress.heartbeat() != nil {
					cancelWork()
					return
				}
			}
		}
	}()
	return func() {
		stop()
		<-done
	}
}
