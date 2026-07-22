package preflight

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

func fakeDoctor(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "ai.sh")
	log := filepath.Join(dir, "calls.log")
	body := `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALL_LOG"
if [ "${TEST_SLEEP:-0}" != 0 ]; then sleep "$TEST_SLEEP"; fi
case "${1:-}" in
  _build-watch-config)
    [ -z "${TEST_CONFIG_STDERR:-}" ] || printf '%s\n' "$TEST_CONFIG_STDERR" >&2
    printf '%s\n' "$TEST_CONFIG_JSON"
    ;;
  _doctor-config-json)
    cat > "$TEST_CONFIG_CAPTURE"
    printf '%s\n' "$TEST_DOCTOR_JSON"
    ;;
  *)
    printf '%s\n' "$TEST_DOCTOR_JSON"
    ;;
esac
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
	payload := `{"ok":true,"backend":{"mode":"codex","path":"/Users/test/bin/codex","version":"0.144.4","identity":"1:2:3:4","source":"path","model":"gpt-5.3-codex-spark","effort":"high","model_source":"default","effort_source":"default","compatible":true},"model":"gpt-5.3-codex-spark","effort":"high","candidates":[]}`
	checker := Checker{EngineScript: script, Env: []string{"TEST_CALL_LOG=" + log, "TEST_DOCTOR_JSON=" + payload}}
	result, err := checker.Check(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.Backend.Path != "/Users/test/bin/codex" || result.Model != "gpt-5.3-codex-spark" {
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

func TestCheckerLoadsAndPreflightsTheExactReviewedConfig(t *testing.T) {
	t.Parallel()
	script, log := fakeDoctor(t)
	capture := filepath.Join(t.TempDir(), "reviewed.json")

	effective := runmodel.DefaultConfig("%145", "")
	effective.Values.Model = runmodel.Value[string]{
		Value: "gpt-5.3-codex-spark", Source: runmodel.SourceTMUX,
	}
	effectivePayload, err := json.Marshal(effective)
	if err != nil {
		t.Fatal(err)
	}
	backendPayload := `{"ok":true,"backend":{"mode":"codex","path":"/Users/test/bin/codex","version":"0.144.4","identity":"1:2:3:4","source":"path","model":"custom-model","effort":"medium","model_source":"custom","effort_source":"custom","compatible":true},"model":"custom-model","effort":"medium","candidates":[]}`
	checker := Checker{EngineScript: script, Env: []string{
		"TEST_CALL_LOG=" + log,
		"TEST_CONFIG_JSON=" + string(effectivePayload),
		"TEST_CONFIG_CAPTURE=" + capture,
		"TEST_DOCTOR_JSON=" + backendPayload,
	}}

	loaded, err := checker.LoadConfig(context.Background(), "%145")
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Values.Model != effective.Values.Model {
		t.Fatalf("loaded model = %#v, want %#v", loaded.Values.Model, effective.Values.Model)
	}

	reviewed := loaded
	reviewed.Values.Model = runmodel.Value[string]{Value: "custom-model", Source: runmodel.SourceCustom}
	reviewed.Values.Effort = runmodel.Value[string]{Value: "medium", Source: runmodel.SourceCustom}
	result, err := checker.CheckConfig(context.Background(), reviewed)
	if err != nil {
		t.Fatal(err)
	}
	if result.Backend.Model != "custom-model" || result.Backend.ModelSource != runmodel.SourceCustom {
		t.Fatalf("preflight backend = %#v", result.Backend)
	}
	payload, err := os.ReadFile(capture)
	if err != nil {
		t.Fatal(err)
	}
	captured, err := runmodel.DecodeConfig(payload)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(captured, reviewed) {
		t.Fatalf("reviewed config changed in transit\n got: %#v\nwant: %#v", captured, reviewed)
	}
	calls, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if string(calls) != "_build-watch-config %145 \n_doctor-config-json\n" {
		t.Fatalf("preflight commands = %q", calls)
	}
}

func TestCheckerRejectsEffectiveConfigDiagnostics(t *testing.T) {
	t.Parallel()
	script, log := fakeDoctor(t)
	effective, err := json.Marshal(runmodel.DefaultConfig("%145", ""))
	if err != nil {
		t.Fatal(err)
	}
	checker := Checker{EngineScript: script, Env: []string{
		"TEST_CALL_LOG=" + log,
		"TEST_CONFIG_JSON=" + string(effective),
		"TEST_CONFIG_STDERR=rejected effort=impossible; allowed: one of minimal, low, medium, high, xhigh",
	}}

	_, err = checker.LoadConfig(context.Background(), "%145")
	if err == nil || !strings.Contains(err.Error(), "rejected effort=impossible") {
		t.Fatalf("effective config diagnostic was ignored: %v", err)
	}
}
