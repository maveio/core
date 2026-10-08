package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const mediaProtocols = "file,http,https,tcp,tls,crypto,pipe"

func mediaCommand(ctx context.Context, executable string, args ...string) *exec.Cmd {
	args = restrictedMediaArgs(args)
	var configErr error
	switch os.Getenv("MAVE_MEDIA_SANDBOX") {
	case "", "disabled": // Native development; container images require confinement.
	case "required":
		resolved, err := exec.LookPath(executable)
		if err != nil {
			configErr = err
		}
		args = append(append(scratchArguments(args), "--", resolved), args...)
		executable = "mave-media-broker"
	default:
		configErr = errors.New("invalid MAVE_MEDIA_SANDBOX mode")
	}
	command := exec.CommandContext(ctx, executable, args...)
	if configErr != nil {
		command.Err = configErr
	}
	command.Env = []string{}
	for _, key := range []string{"PATH", "LANG", "LC_ALL", "MAVE_MEDIA_MAX_ADDRESS_BYTES",
		"MAVE_MEDIA_MAX_FILE_BYTES", "MAVE_MEDIA_MAX_CPU_SECONDS", "MAVE_MEDIA_SANDBOX_BACKEND", "MAVE_MEDIA_SANDBOX_GPU", "CUDA_VISIBLE_DEVICES"} {
		if value, exists := os.LookupEnv(key); exists {
			command.Env = append(command.Env, key+"="+value)
		}
	}
	return command
}

func restrictedMediaArgs(args []string) []string {
	result := []string{"-nostdin"}
	explicit := false
	for _, arg := range args {
		if arg == "-protocol_whitelist" {
			explicit = true
		}
		if arg == "-i" {
			if !explicit {
				result = append(result, "-protocol_whitelist", mediaProtocols)
			}
			explicit = false
		}
		result = append(result, arg)
	}
	if !hasArgument(args, "-i") && !explicit {
		result = append([]string{"-protocol_whitelist", mediaProtocols}, result...)
	}
	return result
}

func hasArgument(args []string, value string) bool {
	for _, arg := range args {
		if arg == value {
			return true
		}
	}
	return false
}

func scratchArguments(args []string) []string {
	root, err := filepath.Abs(bundleTempDir())
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var result []string
	for _, arg := range args {
		if !filepath.IsAbs(arg) || !strings.HasPrefix(arg, root+string(os.PathSeparator)) {
			continue
		}
		relative, err := filepath.Rel(root, filepath.Clean(arg))
		if err != nil || relative == ".." || strings.HasPrefix(relative, "../") {
			continue
		}
		// Grant only the referenced job directory (or the pre-created frame file).
		path := filepath.Join(root, strings.Split(relative, string(os.PathSeparator))[0])
		if !seen[path] {
			result = append(result, "--scratch", path)
			seen[path] = true
		}
	}
	return result
}

// CombinedOutput otherwise grows without a limit when a malformed input causes
// repeated diagnostics. Streaming paths already use recentLog.
type boundedCommandOutput struct{ data []byte }

func (output *boundedCommandOutput) Write(data []byte) (int, error) {
	const limit = 1024 * 1024
	size := len(data)
	if len(data) >= limit {
		output.data = append(output.data[:0], data[len(data)-limit:]...)
	} else {
		if excess := len(output.data) + len(data) - limit; excess > 0 {
			copy(output.data, output.data[excess:])
			output.data = output.data[:len(output.data)-excess]
		}
		output.data = append(output.data, data...)
	}
	return size, nil
}

func mediaCommandOutput(command *exec.Cmd) ([]byte, error) {
	output := &boundedCommandOutput{}
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	return output.data, err
}
