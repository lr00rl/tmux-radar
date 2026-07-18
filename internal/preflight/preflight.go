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
	"strings"
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
	return checker.check(ctx, nil, "doctor-json")
}

func (checker Checker) LoadConfig(ctx context.Context, pane string) (runmodel.Config, error) {
	stdout, stderr, err := checker.invoke(ctx, nil, "_build-watch-config", pane, "")
	if err != nil {
		return runmodel.Config{}, err
	}
	if diagnostic := strings.TrimSpace(string(stderr)); diagnostic != "" {
		return runmodel.Config{}, fmt.Errorf("preflight: effective config rejected: %s", diagnostic)
	}
	config, err := runmodel.DecodeReviewedConfigStrict(stdout)
	if err != nil {
		return runmodel.Config{}, fmt.Errorf("preflight: effective config: %w", err)
	}
	if config.Pane != pane {
		return runmodel.Config{}, fmt.Errorf(
			"preflight: effective config pane %q does not match requested pane %q", config.Pane, pane,
		)
	}
	return config, nil
}

func (checker Checker) CheckConfig(ctx context.Context, config runmodel.Config) (Result, error) {
	config.Backend = nil
	if err := config.Validate(); err != nil {
		return Result{}, fmt.Errorf("preflight: reviewed config: %w", err)
	}
	payload, err := json.Marshal(config)
	if err != nil {
		return Result{}, fmt.Errorf("preflight: encode reviewed config: %w", err)
	}
	return checker.check(ctx, append(payload, '\n'), "_doctor-config-json")
}

func (checker Checker) check(ctx context.Context, stdin []byte, args ...string) (Result, error) {
	stdout, _, err := checker.invoke(ctx, stdin, args...)
	if err != nil {
		return Result{}, err
	}

	var result Result
	decoder := json.NewDecoder(bytes.NewReader(stdout))
	if err := decoder.Decode(&result); err != nil {
		return Result{}, fmt.Errorf("preflight: malformed doctor JSON: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return Result{}, errors.New("preflight: doctor returned multiple JSON values")
		}
		return Result{}, fmt.Errorf("preflight: trailing doctor JSON: %w", err)
	}
	if result.OK && result.Backend.Mode != "codex" && result.Backend.Mode != "custom-command" {
		return Result{}, fmt.Errorf("preflight: unsupported backend mode %q", result.Backend.Mode)
	}
	return result, nil
}

func (checker Checker) invoke(ctx context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
	if checker.EngineScript == "" {
		return nil, nil, errors.New("preflight: engine script is required")
	}
	operation := "engine"
	if len(args) > 0 {
		operation = args[0]
	}
	timeout := checker.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	command := exec.CommandContext(callCtx, "bash", append([]string{checker.EngineScript}, args...)...)
	configureProcessGroup(command)
	command.Env = mergeEnv(os.Environ(), checker.Env)
	if stdin != nil {
		command.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	if callCtx.Err() != nil {
		return nil, nil, fmt.Errorf("preflight: %s timed out: %w", operation, callCtx.Err())
	}
	if stdout.Len() > maxOutputBytes || stderr.Len() > maxOutputBytes {
		return nil, nil, fmt.Errorf("preflight: %s output exceeded 1 MiB", operation)
	}
	if err != nil {
		return nil, nil, fmt.Errorf(
			"preflight: %s failed: %w: %s", operation, err, bytes.TrimSpace(stderr.Bytes()),
		)
	}
	return stdout.Bytes(), stderr.Bytes(), nil
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
