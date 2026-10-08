package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMediaCommandRemovesSecrets(t *testing.T) {
	t.Setenv("MAVE_MEDIA_SANDBOX", "disabled")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "secret")
	t.Setenv("ENCODER_BEARER_TOKEN", "token")
	t.Setenv("LD_PRELOAD", "/secret.so")
	command := mediaCommand(context.Background(), "ffmpeg", "-version")
	for _, entry := range command.Env {
		if strings.Contains(entry, "secret") || strings.HasPrefix(entry, "ENCODER_BEARER_TOKEN=") {
			t.Fatalf("unsafe inherited environment: %q", entry)
		}
	}
	if !hasArgument(command.Args, mediaProtocols) || !hasArgument(command.Args, "-nostdin") {
		t.Fatalf("missing command restrictions: %v", command.Args)
	}
}

func TestMediaCommandFailsClosedWithoutLauncher(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "ffmpeg"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("MAVE_MEDIA_SANDBOX", "required")
	if _, err := mediaCommandOutput(mediaCommand(context.Background(), "ffmpeg", "-version")); err == nil {
		t.Fatal("executed without required launcher")
	}
	t.Setenv("MAVE_MEDIA_SANDBOX", "typo")
	if err := mediaCommand(context.Background(), "ffmpeg").Run(); err == nil {
		t.Fatal("accepted unknown sandbox mode")
	}
}

func TestScratchArgumentsStayInsideJob(t *testing.T) {
	t.Setenv("BUNDLE_TEMP_DIR", "/var/tmp")
	args := scratchArguments([]string{"-i", "https://example.com/video.mp4", "/var/tmp/job/seg%03d.ts", "/var/tmp/job/playlist.m3u8", "/var/tmp/../../etc/passwd", "/var/tmp-other/secret"})
	if strings.Join(args, " ") != "--scratch /var/tmp/job" {
		t.Fatalf("unexpected grants: %v", args)
	}
}

func TestCommandOutputIsBounded(t *testing.T) {
	output := &boundedCommandOutput{}
	data := bytes.Repeat([]byte("x"), 2*1024*1024)
	if n, err := output.Write(data); err != nil || n != len(data) {
		t.Fatal("short write")
	}
	_, _ = output.Write([]byte("end"))
	if len(output.data) != 1024*1024 || !bytes.HasSuffix(output.data, []byte("end")) {
		t.Fatal("output retention is unbounded or loses the tail")
	}
}

func TestProtocolRestrictionsCoverEveryInput(t *testing.T) {
	args := restrictedMediaArgs([]string{"-protocol_whitelist", "file", "-i", "one.mp4", "-i", "two.mp4"})
	got := strings.Join(args, " ")
	want := "-nostdin -protocol_whitelist file -i one.mp4 -protocol_whitelist " + mediaProtocols + " -i two.mp4"
	if got != want {
		t.Fatalf("unrestricted input: %s", got)
	}
}
