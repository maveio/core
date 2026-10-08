package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Only the SD input is staged, on the booster, never on the application worker.
// Bound disk use even for a response without Content-Length.
const maxSegmentSourceBytes int64 = 8 * 1024 * 1024 * 1024

func prepareSegmentSource(ctx context.Context, writer http.ResponseWriter, request encodeRequest) (string, func(), error) {
	work, err := os.MkdirTemp(bundleTempDir(), "mave-segments-")
	if err != nil {
		return "", func() {}, errors.New("could not create segment source directory")
	}
	cleanup := func() { _ = os.RemoveAll(work) }
	path := filepath.Join(work, "source.mp4")
	encoder, flusher, err := startMultipartResponse(writer)
	if err != nil {
		cleanup()
		return "", func() {}, err
	}

	downloadContext, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- downloadSegmentSource(downloadContext, request, path, maxSegmentSourceBytes, 500*time.Millisecond)
	}()
	ticker := time.NewTicker(multipartHeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case err := <-done:
			if err != nil {
				cleanup()
				return "", func() {}, err
			}
			return path, cleanup, nil
		case <-ticker.C:
			if err := writeUploadEvent(encoder, flusher, uploadEvent{Status: "preparing"}); err != nil {
				cancel()
				<-done
				cleanup()
				return "", func() {}, err
			}
		case <-ctx.Done():
			cancel()
			<-done
			cleanup()
			return "", func() {}, errors.New("segment source download canceled")
		}
	}
}

func downloadSegmentSource(ctx context.Context, request encodeRequest, path string, limit int64, retryDelay time.Duration) error {
	for attempt := 0; attempt < 3; attempt++ {
		// Each retry starts a new file. Never feed a partial download to FFmpeg.
		attemptContext, cancel := context.WithTimeout(ctx, 10*time.Minute)
		retry, err := downloadSegmentSourceAttempt(attemptContext, request, path, limit)
		cancel()
		if err == nil {
			return nil
		}
		_ = os.Remove(path)
		if !retry || attempt == 2 || ctx.Err() != nil {
			return err
		}
		timer := time.NewTimer(retryDelay * time.Duration(1<<attempt))
		select {
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return errors.New("segment source download canceled")
		}
	}
	return errors.New("segment source download failed")
}

func downloadSegmentSourceAttempt(ctx context.Context, request encodeRequest, path string, limit int64) (bool, error) {
	sourceRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, request.InputURL, nil)
	if err != nil {
		return false, errors.New("could not create segment source request")
	}
	sourceRequest.Header.Set("Accept-Encoding", "identity")
	if request.InputReferer != "" {
		sourceRequest.Header.Set("Referer", request.InputReferer)
	}
	if request.InputBasicAuth != "" {
		sourceRequest.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(request.InputBasicAuth)))
	}
	// Reuse the trusted downloader's public-address validation, DNS pinning and
	// redirect rejection. The confined parser only receives the completed file.
	response, err := performSourceRequest(sourceRequest)
	if err != nil {
		return true, errors.New("segment source transport failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		retry := response.StatusCode == 408 || response.StatusCode == 429 || response.StatusCode >= 500
		return retry, fmt.Errorf("segment source returned HTTP %d", response.StatusCode)
	}
	if response.ContentLength > limit {
		return false, fmt.Errorf("segment source exceeds %d-byte download limit", limit)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return false, errors.New("could not create segment source file")
	}
	size, copyErr := io.Copy(file, io.LimitReader(response.Body, limit+1))
	closeErr := file.Close()
	if size > limit {
		return false, fmt.Errorf("segment source exceeds %d-byte download limit", limit)
	}
	var fileErr *os.PathError
	if closeErr != nil || errors.As(copyErr, &fileErr) {
		return false, errors.New("could not write segment source file")
	}
	if copyErr != nil || (response.ContentLength >= 0 && size != response.ContentLength) {
		return true, errors.New("segment source download incomplete")
	}
	if size == 0 {
		return true, errors.New("segment source download empty")
	}
	return false, nil
}
