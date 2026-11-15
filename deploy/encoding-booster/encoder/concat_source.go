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

var errInvalidConcatChunk = errors.New("invalid concat video packets")

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
		frames, err := validateConcatChunk(ctx, path, work)
		if err != nil {
			if errors.Is(err, errInvalidConcatChunk) {
				return concatSources{err: fmt.Errorf("concat chunk %d contains invalid video packets", index)}
			}
			return concatSources{err: errors.New("could not validate concat chunk")}
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

func validateConcatChunk(ctx context.Context, path, work string) (int64, error) {
	// Use the same demuxer and automatic bitstream conversion as the final
	// concat. Plain MP4 stream-copy can miss malformed NAL units in later packets.
	manifest := filepath.Join(work, "validate.ffconcat")
	if err := os.WriteFile(manifest, []byte(concatManifest([]string{path})), 0600); err != nil {
		return 0, err
	}
	command := mediaCommand(ctx, ffmpegExecutable,
		"-hide_banner", "-loglevel", "error", "-xerror", "-abort_on", "empty_output",
		"-progress", "pipe:1", "-nostats", "-f", "concat", "-safe", "0", "-i", manifest,
		"-map", "0:v:0", "-c:v", "copy", "-f", "null", "-")
	progress, diagnostics := &boundedCommandOutput{}, &boundedCommandOutput{}
	command.Stdout, command.Stderr = progress, diagnostics
	err := command.Run()
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	if err != nil && (command.ProcessState == nil || command.ProcessState.ExitCode() < 0) {
		return 0, err
	}
	// FFmpeg can log bitstream errors and still exit zero with some packets.
	// At loglevel=error any diagnostic makes this cached chunk unsafe to reuse.
	if err != nil || len(diagnostics.data) > 0 {
		return 0, errInvalidConcatChunk
	}
	var frames int64
	for _, line := range strings.Split(string(progress.data), "\n") {
		if strings.HasPrefix(line, "frame=") {
			frames, _ = strconv.ParseInt(strings.TrimSpace(strings.TrimPrefix(line, "frame=")), 10, 64)
		}
	}
	if frames <= 0 {
		return 0, errInvalidConcatChunk
	}
	return frames, nil
}
