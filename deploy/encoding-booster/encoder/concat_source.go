package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxConcatSourceBytes int64 = 16 * 1024 * 1024 * 1024

type concatSources struct {
	manifest string
	frames   int64
	err      error
}

func prepareConcatSources(ctx context.Context, writer http.ResponseWriter, request concatRequest) (concatSources, func()) {
	work, err := os.MkdirTemp(bundleTempDir(), "mave-concat-")
	if err != nil {
		return concatSources{err: errors.New("could not create concat workspace")}, func() {}
	}
	cleanup := func() { _ = os.RemoveAll(work) }
	encoder, flusher, err := startMultipartResponse(writer)
	if err != nil {
		return concatSources{err: err}, cleanup
	}
	prepareContext, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan concatSources, 1)
	go func() { done <- downloadConcatSources(prepareContext, request, work, maxConcatSourceBytes) }()
	ticker := time.NewTicker(multipartHeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case result := <-done:
			return result, cleanup
		case <-ticker.C:
			if err := writeUploadEvent(encoder, flusher, uploadEvent{Status: "preparing"}); err != nil {
				cancel()
				<-done
				return concatSources{err: err}, cleanup
			}
		case <-ctx.Done():
			cancel()
			<-done
			return concatSources{err: errors.New("concat source preparation canceled")}, cleanup
		}
	}
}

func downloadConcatSources(ctx context.Context, request concatRequest, work string, limit int64) concatSources {
	var paths []string
	var totalFrames int64
	for index, inputURL := range request.InputURLs {
		path := filepath.Join(work, fmt.Sprintf("chunk-%03d.mp4", index))
		err := downloadSegmentSource(ctx, encodeRequest{InputURL: inputURL, InputReferer: request.InputReferer}, path, limit, 500*time.Millisecond)
		if err != nil {
			return concatSources{err: fmt.Errorf("concat chunk %d: %w", index, err)}
		}
		info, err := os.Stat(path)
		if err != nil {
			return concatSources{err: errors.New("could not inspect downloaded concat chunk")}
		}
		limit -= info.Size()
		// Count video packets by remuxing to null: no decoding, no remote reads.
		// This also rejects old cached chunks containing no video packets.
		output, err := mediaCommandOutput(mediaCommand(ctx, ffmpegExecutable,
			"-hide_banner", "-loglevel", "error", "-xerror", "-abort_on", "empty_output",
			"-progress", "pipe:1", "-nostats", "-i", path, "-map", "0:v:0", "-c:v", "copy", "-f", "null", "-"))
		frames := int64(0)
		for _, line := range strings.Split(string(output), "\n") {
			if strings.HasPrefix(line, "frame=") {
				frames, _ = strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, "frame=")), 10, 64)
			}
		}
		if err != nil || frames <= 0 {
			return concatSources{err: fmt.Errorf("concat chunk %d contains no valid video packets", index)}
		}
		totalFrames += frames
		paths = append(paths, path)
	}
	manifest := filepath.Join(work, "inputs.ffconcat")
	if err := os.WriteFile(manifest, []byte(concatManifest(paths)), 0600); err != nil {
		return concatSources{err: errors.New("could not write local concat manifest")}
	}
	return concatSources{manifest: manifest, frames: totalFrames}
}
