package preflight

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeDoctor(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "ai.sh")
	log := filepath.Join(dir, "calls.log")
	body := `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALL_LOG"
if [ "${TEST_SLEEP:-0}" != 0 ]; then sleep "$TEST_SLEEP"; fi
printf '%s\n' "$TEST_DOCTOR_JSON"
exit "${TEST_EXIT_CODE:-0}"
`
	if err := os.WriteFile(script, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	return script, log
}

func TestCheckerReadsDoctorJSONWithoutLaunchingAModel(t *testing.T) {
	t.Parallel()
	script, log := fakeDoctor(t)
	payload := `{"ok":true,"backend":{"mode":"codex","path":"/Users/test/bin/codex","version":"0.144.4","identity":"1:2:3:4","source":"path","model":"gpt-5.6-luna","effort":"high","model_source":"default","effort_source":"default","compatible":true},"model":"gpt-5.6-luna","effort":"high","candidates":[]}`
	checker := Checker{EngineScript: script, Env: []string{"TEST_CALL_LOG=" + log, "TEST_DOCTOR_JSON=" + payload}}
	result, err := checker.Check(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.Backend.Path != "/Users/test/bin/codex" || result.Model != "gpt-5.6-luna" {
		t.Fatalf("result = %#v", result)
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if string(calls) != "doctor-json\n" || strings.Contains(string(calls), "exec") {
		t.Fatalf("preflight executed unexpected command: %q", calls)
	}
}

func TestCheckerFailsClosedOnMalformedOrMultipleJSON(t *testing.T) {
	t.Parallel()
	for _, payload := range []string{"{bad", `{"ok":true} {"ok":true}`} {
		script, log := fakeDoctor(t)
		checker := Checker{EngineScript: script, Env: []string{"TEST_CALL_LOG=" + log, "TEST_DOCTOR_JSON=" + payload}}
		if _, err := checker.Check(context.Background()); err == nil {
			t.Fatalf("payload %q was accepted", payload)
		}
	}
}

func TestCheckerBoundsDoctorRuntime(t *testing.T) {
	t.Parallel()
	script, log := fakeDoctor(t)
	checker := Checker{
		EngineScript: script,
		Env:          []string{"TEST_CALL_LOG=" + log, "TEST_DOCTOR_JSON={}", "TEST_SLEEP=2"},
		Timeout:      30 * time.Millisecond,
	}
	started := time.Now()
	if _, err := checker.Check(context.Background()); err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("timeout error = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("doctor timeout left descendants alive for %v", elapsed)
	}
}
