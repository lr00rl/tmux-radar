package preflight

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

const maxOutputBytes = 1 << 20

type Candidate struct {
	Path            string `json:"path"`
	Version         string `json:"version"`
	Source          string `json:"source"`
	RequiredVersion string `json:"required_version,omitempty"`
	Compatible      bool   `json:"compatible"`
}

type Result struct {
	OK         bool                     `json:"ok"`
	Backend    runmodel.BackendIdentity `json:"backend"`
	Model      string                   `json:"model"`
	Effort     string                   `json:"effort"`
	Candidates []Candidate              `json:"candidates"`
	Class      string                   `json:"class,omitempty"`
	Summary    string                   `json:"summary,omitempty"`
	Detail     string                   `json:"detail,omitempty"`
}

type Checker struct {
	EngineScript string
	Env          []string
	Timeout      time.Duration
}

func (checker Checker) Check(ctx context.Context) (Result, error) {
	if checker.EngineScript == "" {
		return Result{}, errors.New("preflight: engine script is required")
	}
	timeout := checker.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := exec.CommandContext(callCtx, "bash", checker.EngineScript, "doctor-json")
	configureProcessGroup(command)
	command.Env = mergeEnv(os.Environ(), checker.Env)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if callCtx.Err() != nil {
		return Result{}, fmt.Errorf("preflight: doctor-json timed out: %w", callCtx.Err())
	}
	if stdout.Len() > maxOutputBytes || stderr.Len() > maxOutputBytes {
		return Result{}, errors.New("preflight: doctor-json output exceeded 1 MiB")
	}
	if err != nil {
		return Result{}, fmt.Errorf("preflight: doctor-json failed: %w: %s", err, bytes.TrimSpace(stderr.Bytes()))
	}

	var result Result
	decoder := json.NewDecoder(bytes.NewReader(stdout.Bytes()))
	if err := decoder.Decode(&result); err != nil {
		return Result{}, fmt.Errorf("preflight: malformed doctor JSON: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return Result{}, errors.New("preflight: doctor-json returned multiple JSON values")
		}
		return Result{}, fmt.Errorf("preflight: trailing doctor JSON: %w", err)
	}
	if result.OK && result.Backend.Mode != "codex" && result.Backend.Mode != "custom-command" {
		return Result{}, fmt.Errorf("preflight: unsupported backend mode %q", result.Backend.Mode)
	}
	return result, nil
}

func configureProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return os.ErrProcessDone
		}
		err := syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	command.WaitDelay = time.Second
}

func mergeEnv(base, overrides []string) []string {
	values := make(map[string]string, len(base)+len(overrides))
	order := make([]string, 0, len(base)+len(overrides))
	apply := func(entries []string) {
		for _, entry := range entries {
			for index := 0; index < len(entry); index++ {
				if entry[index] != '=' {
					continue
				}
				key := entry[:index]
				if _, exists := values[key]; !exists {
					order = append(order, key)
				}
				values[key] = entry[index+1:]
				break
			}
		}
	}
	apply(base)
	apply(overrides)
	merged := make([]string, 0, len(order))
	for _, key := range order {
		merged = append(merged, key+"="+values[key])
	}
	return merged
}
