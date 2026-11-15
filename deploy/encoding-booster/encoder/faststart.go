package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// Multipart storage is not seekable. Finish the MP4 on the encoder's scratch
// disk so FFmpeg can put the complete sample index before the media data.
// The application still receives only progress, never the media bytes.
func uploadFaststartVideo(ctx context.Context, writer http.ResponseWriter, args []string, upload multipartUpload, redactions []string) {
	encoder, flusher, err := startMultipartResponse(writer)
	if err != nil {
		abortMultipartUploadBestEffort(upload.AbortURL)
		return
	}
	fail := func(message string) {
		abortMultipartUploadBestEffort(upload.AbortURL)
		_ = writeUploadEvent(encoder, flusher, uploadEvent{Status: "failed", Error: message})
	}
	work, err := os.MkdirTemp(bundleTempDir(), "mave-faststart-")
	if err != nil {
		fail("could not create video workspace")
		return
	}
	defer os.RemoveAll(work)
	outputPath := filepath.Join(work, "output.mp4")
	args = faststartOutputArgs(args, outputPath)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	command := mediaCommand(ctx, ffmpegExecutable, args...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.WaitDelay = 10 * time.Second
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		fail("could not read video encoding progress")
		return
	}
	started := time.Now()
	if err := command.Start(); err != nil {
		fail("could not start video encoding")
		return
	}
	recent := &recentLog{}
	progressDone := make(chan struct{})
	go func() {
		readProgressWithInputs(stderr, redactions, recent)
		close(progressDone)
	}()
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	capacity := upload.PartSizeBytes * int64(len(upload.PartURLs))
	// This path is for short previews, not full-length videos. Bound scratch
	// use independently of the storage destination's permitted upload size.
	capacity = min(capacity, int64(512*1024*1024))
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	nextHeartbeat := time.Now().Add(multipartHeartbeatInterval)
	var workErr error
encoding:
	for {
		select {
		case workErr = <-done:
			break encoding
		case <-ticker.C:
			if info, statErr := os.Stat(outputPath); statErr == nil && info.Size() > capacity {
				workErr = errors.New("encoded output exceeded multipart capacity")
				cancel()
				<-done
				break encoding
			}
			if time.Now().After(nextHeartbeat) {
				if err := writeUploadEvent(encoder, flusher, uploadEvent{Status: "encoding", Metrics: recent.progressSnapshot()}); err != nil {
					workErr = err
					cancel()
					<-done
					break encoding
				}
				nextHeartbeat = time.Now().Add(multipartHeartbeatInterval)
			}
		case <-ctx.Done():
			workErr = ctx.Err()
			<-done
			break encoding
		}
	}
	<-progressDone
	if workErr != nil {
		fail("video encoding failed: " + sanitizedFFmpegDetails(workErr.Error()+": "+recent.string(), redactions...))
		return
	}
	metrics := recent.progressSnapshot()
	frames, err := strconv.ParseInt(metrics["frame"], 10, 64)
	if err != nil || frames <= 0 {
		fail("video output contains no encoded frames")
		return
	}
	output, err := openMediaOutput(outputPath)
	if err != nil {
		fail("could not read completed video")
		return
	}
	defer output.Close()
	info, err := output.Stat()
	if err != nil || info.Size() <= 0 || info.Size() > capacity {
		fail("completed video exceeds multipart capacity or is empty")
		return
	}
	encodingMS := time.Since(started).Milliseconds()
	bytes, parts, err := streamToMultipartUploadWithEvents(ctx, output, upload, encoder, flusher, multipartHeartbeatInterval)
	if err != nil {
		fail("completed video upload failed")
		return
	}
	if err := completeMultipartUpload(ctx, upload.CompleteURL, parts); err != nil {
		fail("could not complete video upload")
		return
	}
	_ = writeUploadEvent(encoder, flusher, uploadEvent{
		Status: "completed", UploadedBytes: bytes, SizeBytes: bytes,
		FFmpegElapsedMS: encodingMS, Metrics: metrics,
	})
}

func faststartOutputArgs(args []string, path string) []string {
	result := []string{"-xerror", "-abort_on", "empty_output"}
	for index := 0; index < len(args); index++ {
		// The duration limit itself enables fragmentation, even with +faststart.
		if args[index] == "-frag_duration" && index+1 < len(args) {
			index++
			continue
		}
		result = append(result, args[index])
	}
	for index := 0; index+1 < len(result); index++ {
		if result[index] == "-movflags" {
			result[index+1] = "+faststart"
		}
	}
	result[len(result)-1] = path
	return result
}
