package enginebridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

const maxOutputBytes = 1 << 20

type StartRequest struct {
	ProtocolVersion     int                       `json:"protocol_version"`
	ConfigSchemaVersion int                       `json:"config_schema_version"`
	StateRoot           string                    `json:"state_root"`
	TargetPane          string                    `json:"target_pane"`
	Config              runmodel.Config           `json:"config"`
	Owner               *runmodel.OwnerDescriptor `json:"owner"`
}

func (request StartRequest) Validate() error {
	if request.ProtocolVersion != runmodel.CurrentProtocolVersion {
		return fmt.Errorf("protocol_version: requires %d", runmodel.CurrentProtocolVersion)
	}
	if request.ConfigSchemaVersion != runmodel.CurrentSchemaVersion || request.Config.SchemaVersion != request.ConfigSchemaVersion {
		return fmt.Errorf("config_schema_version: requires %d and must match config", runmodel.CurrentSchemaVersion)
	}
	if !filepath.IsAbs(request.StateRoot) {
		return errors.New("state_root: absolute path is required")
	}
	if request.TargetPane != request.Config.Pane {
		return errors.New("target_pane: must match config.pane")
	}
	if err := request.Config.ValidateLaunch(); err != nil {
		return fmt.Errorf("config: %w", err)
	}
	if request.Owner != nil {
		if err := validateOwner(*request.Owner); err != nil {
			return err
		}
		if request.Owner.Kind == runmodel.OwnerViewer {
			return errors.New("owner.kind: viewer cannot own a new supervision run")
		}
	}
	return nil
}

func validateOwner(owner runmodel.OwnerDescriptor) error {
	if owner.SchemaVersion != runmodel.CurrentSchemaVersion {
		return fmt.Errorf("owner.schema_version: requires %d", runmodel.CurrentSchemaVersion)
	}
	switch owner.Kind {
	case runmodel.OwnerSplit, runmodel.OwnerPopup:
		if owner.PID <= 0 || len(owner.Token) != 32 || !filepath.IsAbs(owner.HeartbeatPath) {
			return errors.New("owner: active lease requires pid, 128-bit hex token, and absolute heartbeat path")
		}
		for _, char := range owner.Token {
			if !strings.ContainsRune("0123456789abcdefABCDEF", char) {
				return errors.New("owner.token: expected 128-bit hexadecimal token")
			}
		}
		if owner.Kind == runmodel.OwnerSplit && owner.Pane == "" {
			return errors.New("owner.pane: split owner requires a monitor pane")
		}
		if owner.Kind == runmodel.OwnerPopup && owner.Pane != "" {
			return errors.New("owner.pane: popup owner cannot claim a pane")
		}
	case runmodel.OwnerDetached, runmodel.OwnerViewer:
		if owner.PID != 0 || owner.Token != "" || owner.HeartbeatPath != "" || owner.Pane != "" {
			return errors.New("owner: detached/viewer descriptor cannot contain an active lease")
		}
	default:
		return fmt.Errorf("owner.kind: unsupported value %q", owner.Kind)
	}
	return nil
}

type ControlResult struct {
	ProtocolVersion int                    `json:"protocol_version"`
	SchemaVersion   int                    `json:"schema_version"`
	OK              bool                   `json:"ok"`
	Status          string                 `json:"status"`
	RunID           string                 `json:"run_id"`
	Pane            string                 `json:"pane"`
	Action          string                 `json:"action"`
	RequestID       string                 `json:"request_id"`
	EvidencePath    string                 `json:"evidence_path,omitempty"`
	Error           *runmodel.BackendError `json:"error,omitempty"`
}

type Bridge struct {
	EngineScript   string
	Env            []string
	StartTimeout   time.Duration
	ControlTimeout time.Duration
	StopTimeout    time.Duration
}

func (bridge Bridge) Start(ctx context.Context, request StartRequest) (runmodel.StartResult, error) {
	if err := request.Validate(); err != nil {
		return runmodel.StartResult{}, err
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return runmodel.StartResult{}, fmt.Errorf("encode start request: %w", err)
	}
	timeout := bridge.StartTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	stdout, commandErr, err := bridge.invoke(ctx, timeout, append(payload, '\n'), "engine-start")
	if err != nil {
		return runmodel.StartResult{}, err
	}
	var result runmodel.StartResult
	if err := decodeOne(stdout, &result); err != nil {
		return runmodel.StartResult{}, fmt.Errorf("decode engine-start result: %w", err)
	}
	if result.ProtocolVersion != runmodel.CurrentProtocolVersion {
		return runmodel.StartResult{}, fmt.Errorf("engine-start protocol mismatch: got %d want %d", result.ProtocolVersion, runmodel.CurrentProtocolVersion)
	}
	if result.OK {
		if !oneOf(result.Status, "started", "already-active") {
			return runmodel.StartResult{}, fmt.Errorf("engine-start success has invalid status %q", result.Status)
		}
		if result.RunID == "" || result.RunDir == "" || result.WatcherPID <= 0 || result.Error != nil {
			return runmodel.StartResult{}, errors.New("engine-start success is missing canonical run identity")
		}
	} else if result.Status == "" || result.Error == nil {
		return runmodel.StartResult{}, errors.New("engine-start failure is missing structured error evidence")
	}
	if commandErr != nil && result.OK {
		return runmodel.StartResult{}, fmt.Errorf("engine-start exited unsuccessfully after claiming success: %w", commandErr)
	}
	return result, nil
}

func (bridge Bridge) Control(ctx context.Context, runID, pane, action, requestID string) (ControlResult, error) {
	if runID == "" || pane == "" || requestID == "" {
		return ControlResult{}, errors.New("control: run ID, pane, and request ID are required")
	}
	if !oneOf(action, "pause", "resume", "reassess", "keep", "stop", "detach") {
		return ControlResult{}, fmt.Errorf("control: unsupported action %q", action)
	}
	return bridge.control(ctx, runID, pane, action, requestID, nil)
}

func (bridge Bridge) TakeoverOwner(ctx context.Context, runID, pane, requestID string, owner runmodel.OwnerDescriptor) (ControlResult, error) {
	if runID == "" || pane == "" || requestID == "" {
		return ControlResult{}, errors.New("takeover owner: run ID, pane, and request ID are required")
	}
	if err := validateOwner(owner); err != nil {
		return ControlResult{}, err
	}
	if owner.Kind != runmodel.OwnerSplit && owner.Kind != runmodel.OwnerPopup {
		return ControlResult{}, errors.New("takeover owner: requires a split or popup owner lease")
	}
	payload, err := json.Marshal(owner)
	if err != nil {
		return ControlResult{}, fmt.Errorf("encode takeover owner: %w", err)
	}
	return bridge.control(ctx, runID, pane, "takeover-owner", requestID, append(payload, '\n'))
}

func (bridge Bridge) control(ctx context.Context, runID, pane, action, requestID string, stdin []byte) (ControlResult, error) {
	timeout := bridge.ControlTimeout
	if action == "stop" {
		timeout = bridge.StopTimeout
		if timeout <= 0 {
			timeout = 10 * time.Second
		}
	} else if timeout <= 0 {
		timeout = 5 * time.Second
	}
	stdout, commandErr, err := bridge.invoke(ctx, timeout, stdin, "control", runID, pane, action, requestID)
	if err != nil {
		return ControlResult{}, err
	}
	var result ControlResult
	if err := decodeOne(stdout, &result); err != nil {
		return ControlResult{}, fmt.Errorf("decode control result: %w", err)
	}
	if result.ProtocolVersion != runmodel.CurrentProtocolVersion {
		return ControlResult{}, fmt.Errorf("control protocol mismatch: got %d want %d", result.ProtocolVersion, runmodel.CurrentProtocolVersion)
	}
	if result.SchemaVersion != runmodel.CurrentSchemaVersion {
		return ControlResult{}, fmt.Errorf("control schema mismatch: got %d want %d", result.SchemaVersion, runmodel.CurrentSchemaVersion)
	}
	if result.RunID != runID || result.Pane != pane || result.Action != action || result.RequestID != requestID {
		return ControlResult{}, errors.New("control result identity does not match request")
	}
	if result.OK {
		if result.Status != "acknowledged" || result.Error != nil {
			return ControlResult{}, errors.New("control success is missing a canonical acknowledgement")
		}
	} else if result.Status == "" || result.Error == nil {
		return ControlResult{}, errors.New("control failure is missing structured error evidence")
	}
	if commandErr != nil && result.OK {
		return ControlResult{}, fmt.Errorf("control exited unsuccessfully after claiming success: %w", commandErr)
	}
	return result, nil
}

func (bridge Bridge) invoke(ctx context.Context, timeout time.Duration, stdin []byte, args ...string) ([]byte, error, error) {
	if bridge.EngineScript == "" {
		return nil, nil, errors.New("engine bridge: script is required")
	}
	callCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	command := exec.CommandContext(callCtx, "bash", append([]string{bridge.EngineScript}, args...)...)
	configureProcessGroup(command)
	command.Env = mergeEnv(os.Environ(), bridge.Env)
	command.Stdin = bytes.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	commandErr := command.Run()
	if callCtx.Err() != nil {
		return nil, commandErr, fmt.Errorf("engine bridge timed out: %w", callCtx.Err())
	}
	if stdout.Len() > maxOutputBytes || stderr.Len() > maxOutputBytes {
		return nil, commandErr, errors.New("engine bridge output exceeded 1 MiB")
	}
	if commandErr != nil && stdout.Len() == 0 {
		return nil, commandErr, fmt.Errorf("engine bridge failed: %w: %s", commandErr, bytes.TrimSpace(stderr.Bytes()))
	}
	return stdout.Bytes(), commandErr, nil
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

func decodeOne(payload []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("multiple JSON values")
	}
	return err
}

func oneOf(value string, allowed ...string) bool {
	for _, candidate := range allowed {
		if value == candidate {
			return true
		}
	}
	return false
}

func mergeEnv(base, overrides []string) []string {
	values := make(map[string]string, len(base)+len(overrides))
	order := make([]string, 0, len(base)+len(overrides))
	for _, entries := range [][]string{base, overrides} {
		for _, entry := range entries {
			key, value, ok := strings.Cut(entry, "=")
			if !ok {
				continue
			}
			if _, exists := values[key]; !exists {
				order = append(order, key)
			}
			values[key] = value
		}
	}
	merged := make([]string, 0, len(order))
	for _, key := range order {
		merged = append(merged, key+"="+values[key])
	}
	return merged
}
