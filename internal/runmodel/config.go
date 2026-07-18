package runmodel

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

const DefaultGoal = "推进当前任务直到完成"

func DefaultConfig(pane, goal string) Config {
	goalSource := SourceCustom
	if goal == "" {
		goal = DefaultGoal
		goalSource = SourceDefault
	}
	defaultString := func(value string) Value[string] {
		return Value[string]{Value: value, Source: SourceDefault}
	}
	defaultInt := func(value int) Value[int] {
		return Value[int]{Value: value, Source: SourceDefault}
	}

	return Config{
		SchemaVersion: CurrentSchemaVersion,
		Pane:          pane,
		Goal:          goal,
		Values: ConfigValues{
			Goal:                  Value[string]{Value: goal, Source: goalSource},
			Autonomy:              defaultString("auto-safe"),
			ApprovalPolicy:        defaultString("safe-auto"),
			AlwaysAllow:           defaultString("off"),
			HooksFirst:            defaultString("on"),
			Poll:                  Value[float64]{Value: 5, Source: SourceDefault},
			StableScreenThreshold: defaultInt(1),
			Command:               defaultString(""),
			Profile:               defaultString(""),
			Model:                 defaultString("gpt-5.6-luna"),
			Effort:                defaultString("high"),
			Timeout:               defaultInt(120),
			MaxDecisions:          defaultInt(40),
			RetryLimit:            defaultInt(3),
			RetryBackoff:          defaultInt(15),
			CaptureLines:          defaultInt(120),
			MonitorExcerptLines:   defaultInt(16),
			MonitorPosition:       defaultString("right"),
			MonitorWidth:          defaultInt(84),
			OverviewRatio:         defaultInt(25),
			CompletionCloseDelay:  defaultInt(12),
			Logging:               defaultString("decision"),
			ScreenSnapshots:       defaultString("off"),
			RetentionDays:         defaultInt(7),
		},
	}
}

func EncodeConfig(config Config) ([]byte, error) {
	if config.SchemaVersion != CurrentSchemaVersion {
		return nil, fmt.Errorf("schema_version: launch encoding requires version %d", CurrentSchemaVersion)
	}
	if err := config.Validate(); err != nil {
		return nil, err
	}
	return json.Marshal(config)
}

// DecodeConfig is the additive, backwards-compatible reader used for durable
// run artifacts. Missing schema_version means v0; unknown fields are ignored.
func DecodeConfig(payload []byte) (Config, error) {
	var probe struct {
		SchemaVersion *int              `json:"schema_version"`
		Pane          string            `json:"pane"`
		Goal          string            `json:"goal"`
		Policy        string            `json:"policy"`
		Autonomy      string            `json:"autonomy"`
		Poll          *float64          `json:"poll"`
		MaxCalls      *int              `json:"max_calls"`
		Provenance    map[string]string `json:"provenance"`
	}
	if err := json.Unmarshal(payload, &probe); err != nil {
		return Config{}, fmt.Errorf("config JSON: %w", err)
	}
	version := LegacySchemaVersion
	if probe.SchemaVersion != nil {
		version = *probe.SchemaVersion
	}
	if err := ValidateSchemaVersion(version); err != nil {
		return Config{}, err
	}

	if version == CurrentSchemaVersion {
		var config Config
		if err := json.Unmarshal(payload, &config); err != nil {
			return Config{}, fmt.Errorf("config JSON: %w", err)
		}
		if err := config.Validate(); err != nil {
			return Config{}, fmt.Errorf("config schema v%d: %w", version, err)
		}
		return config, nil
	}

	config := DefaultConfig(probe.Pane, probe.Goal)
	if err := json.Unmarshal(payload, &config); err != nil {
		return Config{}, fmt.Errorf("config JSON: %w", err)
	}
	config.SchemaVersion = LegacySchemaVersion
	applyLegacyFlatConfig(&config, probe.Policy, probe.Autonomy, probe.Poll, probe.MaxCalls, probe.Provenance)
	if config.Goal != config.Values.Goal.Value && config.Values.Goal.Source == SourceDefault {
		config.Values.Goal = Value[string]{Value: config.Goal, Source: SourceDefault}
	}
	return config, nil
}

func applyLegacyFlatConfig(config *Config, policy, autonomy string, poll *float64, maxCalls *int, provenance map[string]string) {
	if policy != "" {
		source := legacySource(provenance["policy"])
		config.Values.ApprovalPolicy = Value[string]{Value: policy, Source: source}
		if policy == "always-allow" {
			config.Values.AlwaysAllow = Value[string]{Value: "on", Source: source}
		}
	}
	if autonomy != "" {
		config.Values.Autonomy = Value[string]{Value: autonomy, Source: legacySource(provenance["autonomy"])}
	}
	if poll != nil {
		config.Values.Poll = Value[float64]{Value: *poll, Source: legacySource(provenance["poll"])}
	}
	if maxCalls != nil {
		config.Values.MaxDecisions = Value[int]{Value: *maxCalls, Source: legacySource(provenance["max_calls"])}
	}
}

func legacySource(value string) Source {
	switch value {
	case "tmux":
		return SourceTMUX
	case "argument":
		return SourceCustom
	case "default":
		return SourceDefault
	default:
		return SourceLegacy
	}
}

// DecodeReviewedConfigStrict is the shell-to-setup boundary. It accepts only a
// complete schema-v1 config and rejects launch state or additive protocol drift.
func DecodeReviewedConfigStrict(payload []byte) (Config, error) {
	config, err := decodeCurrentConfigStrict(payload)
	if err != nil {
		return Config{}, err
	}
	if config.Backend != nil {
		return Config{}, errors.New("strict reviewed config: backend is launch state and is not allowed")
	}
	if config.RunID != "" || config.CreatedAt != "" || config.CreatedEpoch != 0 {
		return Config{}, errors.New("strict reviewed config: run metadata is not allowed")
	}
	if err := config.Validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

// DecodeConfigStrict is the launch boundary. Protocol v1 must send a complete
// v1 config and may not smuggle misspelled or unsupported fields.
func DecodeConfigStrict(payload []byte) (Config, error) {
	config, err := decodeCurrentConfigStrict(payload)
	if err != nil {
		return Config{}, err
	}
	if err := config.ValidateLaunch(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func decodeCurrentConfigStrict(payload []byte) (Config, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	var config Config
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("strict config JSON: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return Config{}, err
	}
	if config.SchemaVersion != CurrentSchemaVersion {
		return Config{}, fmt.Errorf("schema_version: launch requires version %d", CurrentSchemaVersion)
	}
	return config, nil
}

func (config Config) ValidateLaunch() error {
	if err := config.Validate(); err != nil {
		return err
	}
	if config.Backend == nil {
		return errors.New("backend: frozen backend is required at launch")
	}
	return config.Backend.Validate(config)
}

func (backend BackendIdentity) Validate(config Config) error {
	if !oneOf(backend.Mode, "codex", "custom-command") {
		return fmt.Errorf("backend.mode: unsupported value %q", backend.Mode)
	}
	if err := validateModelSource("backend.model_source", backend.ModelSource); err != nil {
		return err
	}
	if err := validateModelSource("backend.effort_source", backend.EffortSource); err != nil {
		return err
	}
	if backend.Model != config.Values.Model.Value || backend.ModelSource != config.Values.Model.Source {
		return errors.New("backend.model: must match the reviewed effective model and provenance")
	}
	if backend.Effort != config.Values.Effort.Value || backend.EffortSource != config.Values.Effort.Source {
		return errors.New("backend.effort: must match the reviewed effective effort and provenance")
	}
	if backend.Profile != config.Values.Profile.Value {
		return errors.New("backend.profile: must match the reviewed profile")
	}
	if backend.Mode == "custom-command" {
		if backend.Command == "" {
			return errors.New("backend.command: custom-command mode requires a command")
		}
		if backend.Command != config.Values.Command.Value {
			return errors.New("backend.command: must match the reviewed effective custom command")
		}
		if !oneOf(backend.Source, "env", "config") {
			return fmt.Errorf("backend.source: unsupported custom-command source %q", backend.Source)
		}
		return nil
	}
	if config.Values.Command.Value != "" || backend.Command != "" {
		return errors.New("backend.command: codex mode cannot include an effective custom command")
	}
	if !strings.HasPrefix(backend.Path, "/") {
		return errors.New("backend.path: codex mode requires an absolute executable path")
	}
	if backend.Version == "" || backend.Identity == "" {
		return errors.New("backend: codex mode requires version and file identity")
	}
	if !oneOf(backend.Source, "path", "tmux") {
		return fmt.Errorf("backend.source: unsupported value %q", backend.Source)
	}
	if !backend.Compatible {
		return errors.New("backend.compatible: model compatibility must pass before launch")
	}
	return nil
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	err := decoder.Decode(&extra)
	if errors.Is(err, io.EOF) {
		return nil
	}
	if err == nil {
		return errors.New("strict config JSON: trailing JSON value")
	}
	return fmt.Errorf("strict config JSON: %w", err)
}

func (config Config) Validate() error {
	if err := ValidateSchemaVersion(config.SchemaVersion); err != nil {
		return err
	}
	if !validPaneID(config.Pane) {
		return fmt.Errorf("pane: expected canonical %%<number>, got %q", config.Pane)
	}
	if config.Goal == "" {
		return errors.New("goal: must not be empty")
	}
	if config.Goal != config.Values.Goal.Value {
		return errors.New("goal: top-level value must match values.goal.value")
	}

	v := config.Values
	if err := validateSource("goal.source", v.Goal.Source); err != nil {
		return err
	}
	if err := validateEnum("autonomy", v.Autonomy, "suggest", "confirm", "auto-safe", "auto"); err != nil {
		return err
	}
	if err := validateEnum("approval_policy", v.ApprovalPolicy, "safe-auto", "manual", "always-allow"); err != nil {
		return err
	}
	if err := validateEnum("always_allow", v.AlwaysAllow, "on", "off"); err != nil {
		return err
	}
	if err := validateEnum("hooks_first", v.HooksFirst, "on", "off"); err != nil {
		return err
	}
	if err := validateFloat("poll", v.Poll, 0.05, 3600); err != nil {
		return err
	}
	if err := validateInt("stable_screen_threshold", v.StableScreenThreshold, 1, 20); err != nil {
		return err
	}
	if err := validateSource("command.source", v.Command.Source); err != nil {
		return err
	}
	if err := validateSource("profile.source", v.Profile.Source); err != nil {
		return err
	}
	if err := validateModelSource("model.source", v.Model.Source); err != nil {
		return err
	}
	if v.Model.Source == SourceProfileManaged && (v.Profile.Value == "" || v.Model.Value != "") {
		return errors.New("model.source: profile-managed requires a profile and an empty explicit value")
	}
	if v.Model.Value == "" && v.Command.Value == "" && v.Model.Source != SourceProfileManaged {
		return errors.New("model: must not be empty without a custom command")
	}
	if v.Effort.Source == SourceProfileManaged {
		if v.Profile.Value == "" || v.Effort.Value != "" {
			return errors.New("effort: profile-managed requires a profile and an empty explicit value")
		}
	} else {
		if err := validateEnum("effort", v.Effort, "minimal", "low", "medium", "high", "xhigh"); err != nil {
			return err
		}
	}
	if err := validateInt("timeout", v.Timeout, 5, 3600); err != nil {
		return err
	}
	if err := validateInt("max_decisions", v.MaxDecisions, 1, 10000); err != nil {
		return err
	}
	if err := validateInt("retry_limit", v.RetryLimit, 0, 10); err != nil {
		return err
	}
	if err := validateInt("retry_backoff", v.RetryBackoff, 0, 3600); err != nil {
		return err
	}
	if err := validateInt("capture_lines", v.CaptureLines, 20, 5000); err != nil {
		return err
	}
	if err := validateInt("monitor_excerpt_lines", v.MonitorExcerptLines, 3, 500); err != nil {
		return err
	}
	if err := validateEnum("monitor_position", v.MonitorPosition, "top", "bottom", "right"); err != nil {
		return err
	}
	if err := validateInt("monitor_width", v.MonitorWidth, 20, 240); err != nil {
		return err
	}
	if err := validateInt("overview_ratio", v.OverviewRatio, 15, 50); err != nil {
		return err
	}
	if err := validateInt("completion_close_delay", v.CompletionCloseDelay, 0, 60); err != nil {
		return err
	}
	if err := validateEnum("logging", v.Logging, "decision", "full"); err != nil {
		return err
	}
	if err := validateEnum("screen_snapshots", v.ScreenSnapshots, "on", "off"); err != nil {
		return err
	}
	if err := validateInt("retention_days", v.RetentionDays, 0, 3650); err != nil {
		return err
	}
	return nil
}

func validateEnum(field string, value Value[string], allowed ...string) error {
	if err := validateSource(field+".source", value.Source); err != nil {
		return err
	}
	if !oneOf(value.Value, allowed...) {
		return fmt.Errorf("%s: unsupported value %q", field, value.Value)
	}
	return nil
}

func validateInt(field string, value Value[int], min, max int) error {
	if err := validateSource(field+".source", value.Source); err != nil {
		return err
	}
	if value.Value < min || value.Value > max {
		return fmt.Errorf("%s: %d outside [%d,%d]", field, value.Value, min, max)
	}
	return nil
}

func validateFloat(field string, value Value[float64], min, max float64) error {
	if err := validateSource(field+".source", value.Source); err != nil {
		return err
	}
	if value.Value < min || value.Value > max {
		return fmt.Errorf("%s: %g outside [%g,%g]", field, value.Value, min, max)
	}
	return nil
}

func validateSource(field string, source Source) error {
	if !oneOf(string(source), string(SourceDefault), string(SourceTMUX), string(SourceCustom), string(SourceRuntime), string(SourcePreset), string(SourceLegacy)) {
		return fmt.Errorf("%s: unsupported value %q", field, source)
	}
	return nil
}

func validateModelSource(field string, source Source) error {
	if source == SourceProfileManaged {
		return nil
	}
	return validateSource(field, source)
}

func validPaneID(pane string) bool {
	if !strings.HasPrefix(pane, "%") || len(pane) < 2 {
		return false
	}
	for _, char := range pane[1:] {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}
