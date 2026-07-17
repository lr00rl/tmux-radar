package enginebridge

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

func fakeEngine(t *testing.T) (string, string, string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "ai.sh")
	args := filepath.Join(dir, "args.log")
	stdin := filepath.Join(dir, "stdin.json")
	body := `#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_ARGS_LOG"
case "${1:-}" in
  engine-start)
    cat > "$TEST_STDIN_LOG"
    [ "${TEST_SLEEP:-0}" = 0 ] || sleep "$TEST_SLEEP"
    printf '%s\n' "$TEST_START_RESULT"
    ;;
  control)
    cat > "$TEST_STDIN_LOG"
    [ "${TEST_SLEEP:-0}" = 0 ] || sleep "$TEST_SLEEP"
    printf '%s\n' "$TEST_CONTROL_RESULT"
    ;;
esac
exit "${TEST_EXIT_CODE:-0}"
`
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	return script, args, stdin
}

func validRequest(t *testing.T) StartRequest {
	t.Helper()
	config := runmodel.DefaultConfig("%42", "允许所有操作\n直到测试完成")
	config.Backend = &runmodel.BackendIdentity{
		Mode: "codex", Path: "/Users/test/bin/codex", Version: "0.144.4", Identity: "1:2:3:4",
		Source: "path", Model: "gpt-5.6-luna", Effort: "high", ModelSource: runmodel.SourceDefault,
		EffortSource: runmodel.SourceDefault, Compatible: true,
	}
	return StartRequest{
		ProtocolVersion: 1, ConfigSchemaVersion: 1, StateRoot: "/private/tmp/radar-state",
		TargetPane: "%42", Config: config,
	}
}

func TestStartSendsImmutableConfigOnlyThroughStdin(t *testing.T) {
	t.Parallel()
	script, argsPath, stdinPath := fakeEngine(t)
	resultJSON := `{"protocol_version":1,"ok":true,"status":"started","run_id":"run-1","run_dir":"/tmp/run-1","watcher_pid":123}`
	bridge := Bridge{EngineScript: script, Env: []string{
		"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath, "TEST_START_RESULT=" + resultJSON,
	}}
	request := validRequest(t)
	result, err := bridge.Start(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.RunID != "run-1" {
		t.Fatalf("result = %#v", result)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(args) != "engine-start\n" || strings.Contains(string(args), request.Config.Goal) {
		t.Fatalf("private config leaked into argv: %q", args)
	}
	payload, err := os.ReadFile(stdinPath)
	if err != nil {
		t.Fatal(err)
	}
	var decoded StartRequest
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Config.Goal != request.Config.Goal || decoded.TargetPane != "%42" {
		t.Fatalf("stdin request changed: %#v", decoded)
	}
}

func TestStartRejectsInvalidRequestBeforeExecutingEngine(t *testing.T) {
	t.Parallel()
	script, argsPath, stdinPath := fakeEngine(t)
	bridge := Bridge{EngineScript: script, Env: []string{"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath}}
	request := validRequest(t)
	request.ProtocolVersion = 2
	if _, err := bridge.Start(context.Background(), request); err == nil {
		t.Fatal("invalid protocol was accepted")
	}
	if _, err := os.Stat(argsPath); !os.IsNotExist(err) {
		t.Fatalf("engine ran for invalid request: %v", err)
	}
}

func TestStartRejectsViewerOwnerBeforeExecutingEngine(t *testing.T) {
	t.Parallel()
	script, argsPath, stdinPath := fakeEngine(t)
	bridge := Bridge{EngineScript: script, Env: []string{"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath}}
	request := validRequest(t)
	request.Owner = &runmodel.OwnerDescriptor{SchemaVersion: 1, Kind: runmodel.OwnerViewer}
	if _, err := bridge.Start(context.Background(), request); err == nil || !strings.Contains(err.Error(), "viewer") {
		t.Fatalf("viewer owner error = %v", err)
	}
	if _, err := os.Stat(argsPath); !os.IsNotExist(err) {
		t.Fatalf("engine ran for viewer owner: %v", err)
	}
}

func TestStartRejectsMalformedAndMismatchedResults(t *testing.T) {
	t.Parallel()
	for _, result := range []string{
		"{bad",
		`{"protocol_version":2,"ok":true,"status":"started"}`,
		`{"protocol_version":1,"ok":true} {"ok":true}`,
		`{"protocol_version":1,"ok":true,"status":"started","run_id":"run-1","run_dir":"/tmp/run-1","watcher_pid":123,"surprise":true}`,
		`{"protocol_version":1,"ok":true,"status":"started"}`,
		`{"protocol_version":1,"ok":true,"status":"starting","run_id":"run-1","run_dir":"/tmp/run-1","watcher_pid":123}`,
	} {
		script, argsPath, stdinPath := fakeEngine(t)
		bridge := Bridge{EngineScript: script, Env: []string{
			"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath, "TEST_START_RESULT=" + result,
		}}
		if _, err := bridge.Start(context.Background(), validRequest(t)); err == nil {
			t.Fatalf("result %q was accepted", result)
		}
	}
}

func TestControlRejectsProtocolDriftAndIncompleteAcknowledgements(t *testing.T) {
	t.Parallel()
	results := []string{
		`{"protocol_version":1,"schema_version":2,"ok":true,"status":"acknowledged","run_id":"run-1","pane":"%42","action":"pause","request_id":"req-1"}`,
		`{"protocol_version":1,"schema_version":1,"ok":true,"status":"pending","run_id":"run-1","pane":"%42","action":"pause","request_id":"req-1"}`,
		`{"protocol_version":1,"schema_version":1,"ok":true,"status":"acknowledged","run_id":"run-1","pane":"%42","action":"pause","request_id":"req-1","surprise":true}`,
		`{"protocol_version":1,"schema_version":1,"ok":false,"status":"timeout","run_id":"run-1","pane":"%42","action":"pause","request_id":"req-1"}`,
	}
	for _, result := range results {
		script, argsPath, stdinPath := fakeEngine(t)
		bridge := Bridge{EngineScript: script, Env: []string{
			"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath, "TEST_CONTROL_RESULT=" + result,
		}}
		if _, err := bridge.Control(context.Background(), "run-1", "%42", "pause", "req-1"); err == nil {
			t.Fatalf("control result %q was accepted", result)
		}
	}
}

func TestControlBindsResultIdentityAndUsesStopTimeout(t *testing.T) {
	t.Parallel()
	script, argsPath, stdinPath := fakeEngine(t)
	result := `{"protocol_version":1,"schema_version":1,"ok":true,"status":"acknowledged","run_id":"run-1","pane":"%42","action":"pause","request_id":"req-1"}`
	bridge := Bridge{EngineScript: script, Env: []string{
		"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath, "TEST_CONTROL_RESULT=" + result,
	}}
	control, err := bridge.Control(context.Background(), "run-1", "%42", "pause", "req-1")
	if err != nil || !control.OK {
		t.Fatalf("control = %#v err=%v", control, err)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(args) != "control run-1 %42 pause req-1\n" {
		t.Fatalf("control args = %q", args)
	}

	timeoutBridge := bridge
	timeoutBridge.Env = append(timeoutBridge.Env, "TEST_SLEEP=2")
	timeoutBridge.StopTimeout = 30 * time.Millisecond
	started := time.Now()
	if _, err := timeoutBridge.Control(context.Background(), "run-1", "%42", "stop", "req-2"); err == nil {
		t.Fatal("stop timeout was accepted")
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("control timeout left descendants alive for %v", elapsed)
	}
}

func TestTakeoverOwnerSendsLeaseOnlyThroughStdin(t *testing.T) {
	t.Parallel()
	script, argsPath, stdinPath := fakeEngine(t)
	result := `{"protocol_version":1,"schema_version":1,"ok":true,"status":"acknowledged","run_id":"run-1","pane":"%42","action":"takeover-owner","request_id":"req-owner"}`
	bridge := Bridge{EngineScript: script, Env: []string{
		"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath, "TEST_CONTROL_RESULT=" + result,
	}}
	owner := runmodel.OwnerDescriptor{
		SchemaVersion: 1,
		Kind:          runmodel.OwnerPopup,
		PID:           1234,
		Token:         "0123456789abcdef0123456789abcdef",
		HeartbeatPath: "/private/tmp/tmux-radar-owner.heartbeat",
	}
	control, err := bridge.TakeoverOwner(context.Background(), "run-1", "%42", "req-owner", owner)
	if err != nil || !control.OK {
		t.Fatalf("takeover control = %#v err=%v", control, err)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(args) != "control run-1 %42 takeover-owner req-owner\n" || strings.Contains(string(args), owner.Token) {
		t.Fatalf("owner lease leaked into argv: %q", args)
	}
	payload, err := os.ReadFile(stdinPath)
	if err != nil {
		t.Fatal(err)
	}
	var decoded runmodel.OwnerDescriptor
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded != owner {
		t.Fatalf("stdin owner = %#v want %#v", decoded, owner)
	}
}

func TestTakeoverOwnerRejectsNonOwningDescriptorsBeforeExecutingEngine(t *testing.T) {
	t.Parallel()
	for _, kind := range []runmodel.OwnerKind{runmodel.OwnerDetached, runmodel.OwnerViewer} {
		script, argsPath, stdinPath := fakeEngine(t)
		bridge := Bridge{EngineScript: script, Env: []string{
			"TEST_ARGS_LOG=" + argsPath, "TEST_STDIN_LOG=" + stdinPath,
		}}
		owner := runmodel.OwnerDescriptor{SchemaVersion: 1, Kind: kind}
		if _, err := bridge.TakeoverOwner(context.Background(), "run-1", "%42", "req-owner", owner); err == nil {
			t.Fatalf("owner kind %q was accepted", kind)
		}
		if _, err := os.Stat(argsPath); !os.IsNotExist(err) {
			t.Fatalf("engine ran for owner kind %q: %v", kind, err)
		}
	}
}
