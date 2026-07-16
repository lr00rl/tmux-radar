package runmodel

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestDefaultConfigUsesLunaHighAndTracksProvenance(t *testing.T) {
	t.Parallel()

	goal := "允许所有安全操作，直到任务全部完成"
	config := DefaultConfig("%42", goal)

	if config.SchemaVersion != CurrentSchemaVersion {
		t.Fatalf("schema version = %d, want %d", config.SchemaVersion, CurrentSchemaVersion)
	}
	if config.Pane != "%42" || config.Goal != goal {
		t.Fatalf("target/goal changed: pane=%q goal=%q", config.Pane, config.Goal)
	}
	if config.Values.Goal != (Value[string]{Value: goal, Source: SourceCustom}) {
		t.Fatalf("goal value = %#v", config.Values.Goal)
	}
	if config.Values.Model != (Value[string]{Value: "gpt-5.6-luna", Source: SourceDefault}) {
		t.Fatalf("model value = %#v", config.Values.Model)
	}
	if config.Values.Effort != (Value[string]{Value: "high", Source: SourceDefault}) {
		t.Fatalf("effort value = %#v", config.Values.Effort)
	}
	if config.Values.Poll.Value != 5 || config.Values.Timeout.Value != 120 {
		t.Fatalf("unexpected timing defaults: poll=%v timeout=%v", config.Values.Poll, config.Values.Timeout)
	}
	if err := config.Validate(); err != nil {
		t.Fatalf("default config rejected: %v", err)
	}
}

func TestDefaultConfigUsesExplicitBlankGoalDefault(t *testing.T) {
	t.Parallel()

	config := DefaultConfig("%7", "")
	if config.Goal != DefaultGoal {
		t.Fatalf("goal = %q, want %q", config.Goal, DefaultGoal)
	}
	if config.Values.Goal.Source != SourceDefault {
		t.Fatalf("goal source = %q, want default", config.Values.Goal.Source)
	}
}

func TestConfigV1RoundTripPreservesExactCJKBytes(t *testing.T) {
	t.Parallel()

	goal := "  监控到测试全绿\n然后等待我确认  "
	config := DefaultConfig("%9", goal)
	payload, err := EncodeConfig(config)
	if err != nil {
		t.Fatalf("EncodeConfig: %v", err)
	}
	if !bytes.Contains(payload, []byte("监控到测试全绿")) {
		t.Fatalf("encoded bytes do not contain the original CJK UTF-8 bytes: %q", payload)
	}

	decoded, err := DecodeConfig(payload)
	if err != nil {
		t.Fatalf("DecodeConfig: %v", err)
	}
	if !bytes.Equal([]byte(decoded.Goal), []byte(goal)) {
		t.Fatalf("goal bytes changed: got %x want %x", []byte(decoded.Goal), []byte(goal))
	}
	if decoded.SchemaVersion != 1 {
		t.Fatalf("schema version = %d, want 1", decoded.SchemaVersion)
	}
}

func TestDecodeConfigReadsLegacyV0AndIgnoresAdditiveFields(t *testing.T) {
	t.Parallel()

	payload := []byte(`{
  "pane":"%55",
  "goal":"legacy 目标",
	  "policy":"manual",
	  "autonomy":"confirm",
	  "poll":10,
	  "max_calls":77,
	  "provenance":{"goal":"argument","policy":"argument","autonomy":"argument","poll":"tmux","max_calls":"tmux_or_default"},
  "future":{"field":true}
}`)
	config, err := DecodeConfig(payload)
	if err != nil {
		t.Fatalf("DecodeConfig(v0): %v", err)
	}
	if config.SchemaVersion != LegacySchemaVersion {
		t.Fatalf("schema version = %d, want legacy v0", config.SchemaVersion)
	}
	if config.Goal != "legacy 目标" || config.Values.Goal.Value != "legacy 目标" {
		t.Fatalf("legacy goal was not normalized: %#v", config)
	}
	if config.Values.ApprovalPolicy != (Value[string]{Value: "manual", Source: SourceCustom}) {
		t.Fatalf("legacy policy = %#v", config.Values.ApprovalPolicy)
	}
	if config.Values.Autonomy != (Value[string]{Value: "confirm", Source: SourceCustom}) {
		t.Fatalf("legacy autonomy = %#v", config.Values.Autonomy)
	}
	if config.Values.Poll != (Value[float64]{Value: 10, Source: SourceTMUX}) {
		t.Fatalf("legacy poll = %#v", config.Values.Poll)
	}
	if config.Values.MaxDecisions != (Value[int]{Value: 77, Source: SourceLegacy}) {
		t.Fatalf("legacy max calls = %#v", config.Values.MaxDecisions)
	}
	if config.Values.Model.Value != "gpt-5.6-luna" || config.Values.Effort.Value != "high" {
		t.Fatalf("legacy defaults not filled: model=%#v effort=%#v", config.Values.Model, config.Values.Effort)
	}
}

func TestDecodeConfigUsesLegacySourceWhenProvenanceIsUnknown(t *testing.T) {
	t.Parallel()

	for _, provenance := range []string{"", "runtime-ish", "not_tmux_but_contains_tmux"} {
		payload := []byte(`{"pane":"%55","goal":"legacy","poll":10,"provenance":{"poll":"` + provenance + `"}}`)
		config, err := DecodeConfig(payload)
		if err != nil {
			t.Fatalf("DecodeConfig(%q): %v", provenance, err)
		}
		if config.Values.Poll.Source != SourceLegacy {
			t.Fatalf("provenance %q mapped to %q, want legacy", provenance, config.Values.Poll.Source)
		}
	}
}

func validCodexBackend() *BackendIdentity {
	return &BackendIdentity{
		Mode:            "codex",
		Path:            "/Users/test/.local/bin/codex",
		Version:         "0.144.4",
		Identity:        "1:2:3:4",
		Source:          "path",
		Model:           "gpt-5.6-luna",
		Effort:          "high",
		ModelSource:     SourceDefault,
		EffortSource:    SourceDefault,
		RequiredVersion: "0.144.0",
		Compatible:      true,
	}
}

func TestDecodeConfigStrictRequiresFrozenBackend(t *testing.T) {
	t.Parallel()

	config := DefaultConfig("%8", "strict")
	payload, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = DecodeConfigStrict(payload); err == nil || !strings.Contains(err.Error(), "backend") {
		t.Fatalf("missing backend error = %v", err)
	}

	config.Backend = validCodexBackend()
	payload, err = json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = DecodeConfigStrict(payload); err != nil {
		t.Fatalf("valid frozen backend rejected: %v", err)
	}

	config.Backend.Mode = "auto"
	payload, err = json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = DecodeConfigStrict(payload); err == nil || !strings.Contains(err.Error(), "backend.mode") {
		t.Fatalf("invalid backend mode error = %v", err)
	}
}

func TestDecodeConfigStrictBindsReviewedCustomCommand(t *testing.T) {
	t.Parallel()

	config := DefaultConfig("%8", "strict custom")
	config.Values.Command = Value[string]{Value: "claude --print", Source: SourceCustom}
	config.Backend = &BackendIdentity{
		Mode:         "custom-command",
		Command:      "claude --print",
		Source:       "env",
		Model:        config.Values.Model.Value,
		Effort:       config.Values.Effort.Value,
		ModelSource:  config.Values.Model.Source,
		EffortSource: config.Values.Effort.Source,
	}

	assertStrict := func(t *testing.T, candidate Config, field string) {
		t.Helper()
		payload, err := json.Marshal(candidate)
		if err != nil {
			t.Fatal(err)
		}
		_, err = DecodeConfigStrict(payload)
		if field == "" && err != nil {
			t.Fatalf("valid custom command rejected: %v", err)
		}
		if field != "" && (err == nil || !strings.Contains(err.Error(), field)) {
			t.Fatalf("strict validation error = %v, want field %q", err, field)
		}
	}

	assertStrict(t, config, "")
	mismatch := config
	mismatch.Backend = cloneBackend(config.Backend)
	mismatch.Backend.Command = "different --command"
	assertStrict(t, mismatch, "backend.command")
	invalidSource := config
	invalidSource.Backend = cloneBackend(config.Backend)
	invalidSource.Backend.Source = "unreviewed"
	assertStrict(t, invalidSource, "backend.source")

	codexContradiction := config
	codexContradiction.Backend = validCodexBackend()
	assertStrict(t, codexContradiction, "backend.command")
}

func cloneBackend(backend *BackendIdentity) *BackendIdentity {
	copy := *backend
	return &copy
}

func TestProfileManagedModelAndEffortDoNotClaimDefaults(t *testing.T) {
	t.Parallel()

	config := DefaultConfig("%8", "profile")
	config.Values.Profile = Value[string]{Value: "work", Source: SourceCustom}
	config.Values.Model = Value[string]{Source: SourceProfileManaged}
	config.Values.Effort = Value[string]{Source: SourceProfileManaged}
	config.Backend = validCodexBackend()
	config.Backend.Profile = "work"
	config.Backend.Model = ""
	config.Backend.Effort = ""
	config.Backend.ModelSource = SourceProfileManaged
	config.Backend.EffortSource = SourceProfileManaged

	payload, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeConfigStrict(payload)
	if err != nil {
		t.Fatalf("profile-managed config rejected: %v", err)
	}
	if decoded.Values.Model.Value != "" || decoded.Values.Model.Source != SourceProfileManaged {
		t.Fatalf("model falsely claims a default: %#v", decoded.Values.Model)
	}
}

func TestDecodeConfigRejectsUnsupportedSchema(t *testing.T) {
	t.Parallel()

	_, err := DecodeConfig([]byte(`{"schema_version":2,"pane":"%1","goal":"x"}`))
	if err == nil || !strings.Contains(err.Error(), "schema_version") {
		t.Fatalf("unsupported schema error = %v", err)
	}
}

func TestDecodeConfigRejectsIncompleteCanonicalV1(t *testing.T) {
	t.Parallel()

	_, err := DecodeConfig([]byte(`{"schema_version":1,"pane":"%1","goal":"must not invent defaults"}`))
	if err == nil {
		t.Fatal("incomplete schema-v1 config was filled with invented defaults")
	}
}

func TestDecodeConfigStrictRejectsUnknownLaunchFields(t *testing.T) {
	t.Parallel()

	config := DefaultConfig("%8", "strict")
	payload, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	payload = bytes.Replace(payload, []byte(`"pane":"%8"`), []byte(`"pane":"%8","surprise":true`), 1)

	_, err = DecodeConfigStrict(payload)
	if err == nil || !strings.Contains(err.Error(), "unknown field") {
		t.Fatalf("strict decode error = %v", err)
	}
}

func TestConfigValidationRejectsInvalidEnumsAndNumbers(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		mutate func(*Config)
		field  string
	}{
		{"pane", func(c *Config) { c.Pane = "window:1" }, "pane"},
		{"goal mismatch", func(c *Config) { c.Goal = "different" }, "goal"},
		{"autonomy", func(c *Config) { c.Values.Autonomy.Value = "root" }, "autonomy"},
		{"policy", func(c *Config) { c.Values.ApprovalPolicy.Value = "anything" }, "approval_policy"},
		{"toggle", func(c *Config) { c.Values.HooksFirst.Value = "true" }, "hooks_first"},
		{"effort", func(c *Config) { c.Values.Effort.Value = "ultra" }, "effort"},
		{"poll", func(c *Config) { c.Values.Poll.Value = 0.01 }, "poll"},
		{"timeout", func(c *Config) { c.Values.Timeout.Value = 4 }, "timeout"},
		{"max decisions", func(c *Config) { c.Values.MaxDecisions.Value = 0 }, "max_decisions"},
		{"overview ratio", func(c *Config) { c.Values.OverviewRatio.Value = 51 }, "overview_ratio"},
		{"source", func(c *Config) { c.Values.Model.Source = "magic" }, "model.source"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := DefaultConfig("%1", "goal")
			test.mutate(&config)
			err := config.Validate()
			if err == nil || !strings.Contains(err.Error(), test.field) {
				t.Fatalf("Validate() error = %v, want field %q", err, test.field)
			}
		})
	}
}

func TestArtifactTypesAcceptLegacyAndEncodeV1(t *testing.T) {
	t.Parallel()

	var state State
	if err := json.Unmarshal([]byte(`{"phase":"ARMED","future":1}`), &state); err != nil {
		t.Fatalf("legacy state: %v", err)
	}
	if state.SchemaVersion != 0 || state.Phase != "ARMED" {
		t.Fatalf("legacy state = %#v", state)
	}

	event := Event{SchemaVersion: CurrentSchemaVersion, Kind: "approval", Label: "需要确认"}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(payload, []byte(`"schema_version":1`)) {
		t.Fatalf("event is not versioned: %s", payload)
	}

	decision := Decision{Action: "send", Text: "2", Keys: []string{"Enter"}, Safe: true, Reason: "approved"}
	if err := decision.Validate(); err != nil {
		t.Fatalf("valid decision rejected: %v", err)
	}
	decision.Action = "shell"
	if err := decision.Validate(); err == nil {
		t.Fatal("unknown decision action accepted")
	}
}

func TestBackendErrorUsesCanonicalNestedEvidenceAndNormalizesLegacy(t *testing.T) {
	t.Parallel()

	retryable := false
	event := Event{
		SchemaVersion: 1,
		Kind:          "backend_error",
		Record:        "error",
		Error: &BackendError{
			Class:          "config-permanent",
			Code:           "backend-version-incompatible",
			Retryable:      retryable,
			Summary:        "Codex is too old",
			BackendPath:    "/usr/local/bin/codex",
			BackendVersion: "0.139.0",
			StderrPath:     "/private/run/backend/0001.stderr",
			Call:           1,
			Timestamp:      "2026-07-14T20:00:00Z",
		},
	}
	payload, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(payload, []byte(`"error":{"class":"config-permanent","code":"backend-version-incompatible"`)) {
		t.Fatalf("backend error is not canonical: %s", payload)
	}
	if bytes.Contains(payload, []byte(`"error_class"`)) {
		t.Fatalf("canonical event leaked legacy flat fields: %s", payload)
	}

	var legacy Event
	err = json.Unmarshal([]byte(`{
	  "kind":"backend_error","record":"error","error_class":"transient",
	  "retryable":true,"summary":"temporary","detail":"see stderr",
	  "backend_path":"/bin/codex","backend_version":"0.144.4",
	  "stderr_path":"/tmp/stderr","call":2
	}`), &legacy)
	if err != nil {
		t.Fatal(err)
	}
	if legacy.Error == nil || legacy.Error.Class != "transient" || !legacy.Error.Retryable || legacy.Error.Call != 2 {
		t.Fatalf("legacy error was not normalized: %#v", legacy)
	}
}

func TestBackendErrorCanonicalV1RequiresCompleteNestedEvidence(t *testing.T) {
	t.Parallel()

	valid := Event{
		SchemaVersion: 1,
		Kind:          "backend_error",
		Error: &BackendError{
			Class: "config-permanent", Code: "backend-preflight", Retryable: false,
			Summary: "backend unavailable", Call: 0, Timestamp: "2026-07-15T00:00:00Z",
		},
	}
	payload, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(payload, []byte(`"call":0`)) {
		t.Fatalf("canonical call zero disappeared: %s", payload)
	}
	var decoded Event
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("valid canonical error rejected: %v", err)
	}
	var canonical map[string]any
	if err := json.Unmarshal(payload, &canonical); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		"class", "code", "retryable", "summary", "detail", "backend_mode",
		"backend_path", "backend_version", "stderr_path", "call", "timestamp",
	} {
		fixture, err := json.Marshal(canonical)
		if err != nil {
			t.Fatal(err)
		}
		var missing map[string]any
		if err := json.Unmarshal(fixture, &missing); err != nil {
			t.Fatal(err)
		}
		delete(missing["error"].(map[string]any), field)
		fixture, err = json.Marshal(missing)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(fixture, &decoded); err == nil {
			t.Fatalf("canonical error missing %q was accepted: %s", field, fixture)
		}
	}
	for _, field := range []string{
		"class", "code", "retryable", "summary", "detail", "backend_mode",
		"backend_path", "backend_version", "stderr_path", "call", "timestamp",
	} {
		fixture, err := json.Marshal(canonical)
		if err != nil {
			t.Fatal(err)
		}
		var nullValue map[string]any
		if err := json.Unmarshal(fixture, &nullValue); err != nil {
			t.Fatal(err)
		}
		nullValue["error"].(map[string]any)[field] = nil
		fixture, err = json.Marshal(nullValue)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(fixture, &decoded); err == nil {
			t.Fatalf("canonical error with null %q was accepted: %s", field, fixture)
		}
	}
	contradictoryCall := bytes.Replace(payload, []byte(`"kind":"backend_error"`),
		[]byte(`"kind":"backend_error","call":99`), 1)
	if err := json.Unmarshal(contradictoryCall, &decoded); err == nil {
		t.Fatalf("flat and nested call contradiction was accepted: %s", contradictoryCall)
	}

	invalid := []string{
		`{"schema_version":1,"kind":"backend_error"}`,
		`{"schema_version":1,"kind":"backend_error","error":null}`,
		`{"schema_version":1,"kind":"backend_error","error":{"class":"transient","code":"backend-failed","retryable":true,"summary":"temporary","timestamp":"2026-07-15T00:00:00Z"}}`,
		`{"schema_version":1,"kind":"backend_error","error_class":"transient","error":{"class":"transient","code":"backend-failed","retryable":true,"summary":"temporary","call":1,"timestamp":"2026-07-15T00:00:00Z"}}`,
		`{"schema_version":2,"kind":"backend_error","error":{"class":"transient","code":"backend-failed","retryable":true,"summary":"temporary","call":1,"timestamp":"2026-07-15T00:00:00Z"}}`,
	}
	for _, input := range invalid {
		if err := json.Unmarshal([]byte(input), &decoded); err == nil {
			t.Fatalf("invalid canonical error was accepted: %s", input)
		}
	}
}

func TestEventUnmarshalPreservesCallOnNonErrorEvents(t *testing.T) {
	t.Parallel()

	var event Event
	if err := json.Unmarshal([]byte(`{"kind":"model_started","call":7}`), &event); err != nil {
		t.Fatal(err)
	}
	if event.Call != 7 {
		t.Fatalf("event call = %d, want 7", event.Call)
	}
}
