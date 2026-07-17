package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
	"github.com/lr00rl/tmux-radar/internal/tui"
)

func withProgramRunner(t *testing.T, runner programRunner) {
	t.Helper()
	previous := launchProgram
	launchProgram = runner
	t.Cleanup(func() { launchProgram = previous })
}

func TestRunVersion(t *testing.T) {
	previous := buildVersion
	buildVersion = "v0.1.0-test"
	t.Cleanup(func() { buildVersion = previous })
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"version"}, strings.NewReader(""), &stdout, &stderr)
	if code != exitOK || !strings.Contains(stdout.String(), "v0.1.0-test") || stderr.Len() != 0 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestRunRejectsInvalidCommandAndSupervisorArguments(t *testing.T) {
	for _, args := range [][]string{
		{"unknown"},
		{"supervisor"},
		{"supervisor", "setup", "--surface", "other", "--target-pane", "%1"},
		{"supervisor", "setup", "--entry", "other", "--target-pane", "%1"},
		{"supervisor", "attach", "--run", "../escape"},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(context.Background(), args, strings.NewReader(""), &stdout, &stderr); code != exitUsage {
			t.Fatalf("args=%v code=%d stdout=%q stderr=%q", args, code, stdout.String(), stderr.String())
		}
	}
}

func TestRunDoctorJSONAndPermanentFailure(t *testing.T) {
	ready := writeFakeEngine(t, true)
	blocked := writeFakeEngine(t, false)
	for _, test := range []struct {
		name   string
		script string
		code   int
		ok     bool
	}{
		{name: "ready", script: ready, code: exitOK, ok: true},
		{name: "blocked", script: blocked, code: exitPermanent, ok: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			code := run(context.Background(), []string{
				"supervisor", "doctor", "--json", "--engine-script", test.script,
			}, strings.NewReader(""), &stdout, &stderr)
			if code != test.code {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			var result map[string]any
			if err := json.Unmarshal(stdout.Bytes(), &result); err != nil {
				t.Fatalf("doctor output: %v\n%s", err, stdout.String())
			}
			if result["ok"] != test.ok {
				t.Fatalf("doctor result=%#v", result)
			}
		})
	}
}

func TestRunSetupCancellationIsSuccessAndLeavesNoHeartbeat(t *testing.T) {
	script := writeFakeEngine(t, true)
	stateRoot := t.TempDir()
	withProgramRunner(t, func(_ context.Context, app *tui.App, _ io.Reader, _ io.Writer) (tea.Model, error) {
		message := tea.KeyPressMsg(tea.Key{Code: 'c', Text: "c", Mod: tea.ModCtrl})
		_, command := app.Update(message)
		if command != nil {
			_ = command()
		}
		return app, nil
	})
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{
		"supervisor", "setup", "--target-pane", "%42", "--monitor-pane", "%99",
		"--surface", "split", "--entry", "quick", "--engine-script", script, "--state-root", stateRoot,
	}, strings.NewReader(""), &stdout, &stderr)
	if code != exitOK {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	entries, err := os.ReadDir(filepath.Join(stateRoot, "ai-owners"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("setup cancellation left heartbeat files: %v", entries)
	}
}

func TestRunAttachMissingAndFinished(t *testing.T) {
	stateRoot := t.TempDir()
	script := writeFakeEngine(t, true)
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{
		"supervisor", "attach", "--run", "missing", "--engine-script", script, "--state-root", stateRoot,
	}, strings.NewReader(""), &stdout, &stderr)
	if code != exitPermanent || !strings.Contains(stderr.String(), "missing") {
		t.Fatalf("missing attach: code=%d stderr=%q", code, stderr.String())
	}

	runDir := filepath.Join(stateRoot, "ai-runs", "run-finished")
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeJSON(t, filepath.Join(runDir, "config.json"), runmodel.DefaultConfig("%42", "done"))
	writeJSON(t, filepath.Join(runDir, "final.json"), runmodel.Final{SchemaVersion: 1, Outcome: "completed", RunID: "run-finished", Pane: "%42"})
	programCalled := false
	withProgramRunner(t, func(_ context.Context, app *tui.App, _ io.Reader, _ io.Writer) (tea.Model, error) {
		programCalled = true
		return app, nil
	})
	stdout.Reset()
	stderr.Reset()
	code = run(context.Background(), []string{
		"supervisor", "attach", "--run", "run-finished", "--engine-script", script, "--state-root", stateRoot,
	}, strings.NewReader(""), &stdout, &stderr)
	if code != exitOK || !programCalled {
		t.Fatalf("finished attach: code=%d called=%v stderr=%q", code, programCalled, stderr.String())
	}
}

func writeFakeEngine(t *testing.T, ready bool) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "ai.sh")
	result := map[string]any{
		"ok": ready,
		"backend": map[string]any{
			"mode": "codex", "path": "/tmp/codex", "version": "0.144.0", "identity": "test",
			"source": "test", "model": "gpt-5.6-luna", "effort": "high", "model_source": "default",
			"effort_source": "default", "compatible": ready,
		},
		"model": "gpt-5.6-luna", "effort": "high", "candidates": []any{},
	}
	if !ready {
		result["class"] = "config-permanent"
		result["summary"] = "backend is incompatible"
		result["detail"] = "upgrade codex"
	}
	payload, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/usr/bin/env bash\nset -eu\nif [ \"${1:-}\" = doctor-json ]; then\n  printf '%s\\n' '" + string(payload) + "'\n  exit 0\nfi\nexit 9\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}
