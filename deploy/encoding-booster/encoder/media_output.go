package main

import (
	"archive/zip"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Only coordinator-owned temporary roots may anchor output reads. OpenRoot
// resolves legitimate system aliases (e.g. macOS /var); descendants are untrusted.
func openMediaOutput(path string) (*os.File, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	var base, relative string
	for _, candidate := range []string{bundleTempDir(), os.TempDir()} {
		root, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		rel, err := filepath.Rel(root, abs)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && len(root) > len(base) {
			base, relative = root, rel
		}
	}
	if base == "" {
		return nil, errors.New("media output is outside temporary roots")
	}
	root, err := os.OpenRoot(base)
	if err != nil {
		return nil, err
	}
	defer func() { _ = root.Close() }()
	parts := strings.Split(relative, string(filepath.Separator))
	for _, part := range parts[:len(parts)-1] {
		before, err := root.Lstat(part)
		if err != nil || !before.IsDir() {
			return nil, errors.New("invalid media output directory")
		}
		next, err := root.OpenRoot(part)
		if err != nil {
			return nil, err
		}
		// Pin the directory inode, not a checked pathname. A replacement between
		// Lstat and OpenRoot must not redirect the subsequent read.
		after, err := next.Stat(".")
		if err != nil || !os.SameFile(before, after) {
			_ = next.Close()
			return nil, errors.New("media output directory changed")
		}
		_ = root.Close()
		root = next
	}
	file, err := root.OpenFile(parts[len(parts)-1], os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		_ = file.Close()
		return nil, errors.New("invalid media output file")
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Nlink != 1 {
		_ = file.Close()
		return nil, errors.New("linked media output file")
	}
	return file, nil
}

func statMediaOutput(path string) (os.FileInfo, error) {
	file, err := openMediaOutput(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

func writeHLSZipEntry(writer *zip.Writer, dir, name string, buffer []byte) error {
	file, err := openMediaOutput(filepath.Join(dir, name))
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	header.Name = "hls/" + name
	header.Method = zip.Store
	entry, err := writer.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = io.CopyBuffer(entry, file, buffer)
	return err
}
