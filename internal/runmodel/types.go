package runmodel

import (
	"bytes"
	"encoding/json"
	"fmt"
)

const (
	LegacySchemaVersion    = 0
	CurrentSchemaVersion   = 1
	CurrentProtocolVersion = 1
)

// Source records why an effective configuration value was selected.
type Source string

const (
	SourceDefault        Source = "default"
	SourceTMUX           Source = "tmux"
	SourceCustom         Source = "custom"
	SourceRuntime        Source = "runtime"
	SourcePreset         Source = "preset"
	SourceLegacy         Source = "legacy"
	SourceProfileManaged Source = "profile-managed"
)

type Value[T any] struct {
	Value  T      `json:"value"`
	Source Source `json:"source"`
}

type ConfigValues struct {
	Goal                  Value[string]  `json:"goal"`
	Autonomy              Value[string]  `json:"autonomy"`
	ApprovalPolicy        Value[string]  `json:"approval_policy"`
	AlwaysAllow           Value[string]  `json:"always_allow"`
	HooksFirst            Value[string]  `json:"hooks_first"`
	Poll                  Value[float64] `json:"poll"`
	StableScreenThreshold Value[int]     `json:"stable_screen_threshold"`
	Command               Value[string]  `json:"command"`
	Profile               Value[string]  `json:"profile"`
	Model                 Value[string]  `json:"model"`
	Effort                Value[string]  `json:"effort"`
	Timeout               Value[int]     `json:"timeout"`
	MaxDecisions          Value[int]     `json:"max_decisions"`
	RetryLimit            Value[int]     `json:"retry_limit"`
	RetryBackoff          Value[int]     `json:"retry_backoff"`
	CaptureLines          Value[int]     `json:"capture_lines"`
	MonitorExcerptLines   Value[int]     `json:"monitor_excerpt_lines"`
	MonitorPosition       Value[string]  `json:"monitor_position"`
	MonitorWidth          Value[int]     `json:"monitor_width"`
	OverviewRatio         Value[int]     `json:"overview_ratio"`
	CompletionCloseDelay  Value[int]     `json:"completion_close_delay"`
	Logging               Value[string]  `json:"logging"`
	ScreenSnapshots       Value[string]  `json:"screen_snapshots"`
	RetentionDays         Value[int]     `json:"retention_days"`
}

type BackendIdentity struct {
	Mode            string `json:"mode,omitempty"`
	Path            string `json:"path,omitempty"`
	Version         string `json:"version,omitempty"`
	Identity        string `json:"identity,omitempty"`
	Source          string `json:"source,omitempty"`
	Profile         string `json:"profile,omitempty"`
	Command         string `json:"command,omitempty"`
	Warning         string `json:"warning,omitempty"`
	Model           string `json:"model,omitempty"`
	Effort          string `json:"effort,omitempty"`
	ModelSource     Source `json:"model_source"`
	EffortSource    Source `json:"effort_source"`
	RequiredVersion string `json:"required_version,omitempty"`
	Compatible      bool   `json:"compatible,omitempty"`
}

type Config struct {
	SchemaVersion int              `json:"schema_version,omitempty"`
	RunID         string           `json:"run_id,omitempty"`
	Pane          string           `json:"pane"`
	Goal          string           `json:"goal"`
	Values        ConfigValues     `json:"values"`
	Backend       *BackendIdentity `json:"backend,omitempty"`
	CreatedAt     string           `json:"created_at,omitempty"`
	CreatedEpoch  int64            `json:"created_epoch,omitempty"`
}

type NextState struct {
	Kind string `json:"kind"`
	At   int64  `json:"at"`
}

type ModelState struct {
	StartedAt int64   `json:"started_at"`
	Elapsed   float64 `json:"elapsed"`
	PID       int     `json:"pid"`
	PGID      int     `json:"pgid"`
	Timeout   int     `json:"timeout"`
	CallCount int     `json:"call_count"`
}

type VerificationState struct {
	PreSendFingerprint string `json:"pre_send_fingerprint,omitempty"`
}

type State struct {
	SchemaVersion      int                `json:"schema_version,omitempty"`
	Phase              string             `json:"phase"`
	Status             string             `json:"status"`
	EventID            string             `json:"event_id,omitempty"`
	Goal               string             `json:"goal,omitempty"`
	Policy             string             `json:"policy,omitempty"`
	Autonomy           string             `json:"autonomy,omitempty"`
	Poll               float64            `json:"poll,omitempty"`
	Calls              int                `json:"calls,omitempty"`
	MaxCalls           int                `json:"max_calls,omitempty"`
	Retry              int                `json:"retry,omitempty"`
	Next               NextState          `json:"next"`
	RunID              string             `json:"run_id,omitempty"`
	Pane               string             `json:"pane,omitempty"`
	UpdatedAt          string             `json:"updated_at,omitempty"`
	WaiterPID          int                `json:"waiter_pid,omitempty"`
	TimerPID           int                `json:"timer_pid,omitempty"`
	Model              ModelState         `json:"model,omitempty"`
	Verification       *VerificationState `json:"verification,omitempty"`
	LatestErrorEventID string             `json:"latest_error_event_id,omitempty"`
}

type Event struct {
	SchemaVersion  int           `json:"schema_version,omitempty"`
	Kind           string        `json:"kind"`
	Source         string        `json:"source,omitempty"`
	Label          string        `json:"label,omitempty"`
	Record         string        `json:"record,omitempty"`
	Phase          string        `json:"phase,omitempty"`
	Status         string        `json:"status,omitempty"`
	RunID          string        `json:"run_id,omitempty"`
	Pane           string        `json:"pane,omitempty"`
	Timestamp      string        `json:"timestamp,omitempty"`
	EventID        string        `json:"event_id,omitempty"`
	Error          *BackendError `json:"error,omitempty"`
	Call           int           `json:"call,omitempty"`
	Retry          int           `json:"retry,omitempty"`
	RepairAttempt  int           `json:"repair_attempt,omitempty"`
	Elapsed        float64       `json:"elapsed,omitempty"`
	RC             int           `json:"rc,omitempty"`
	Sent           *bool         `json:"sent,omitempty"`
	Text           string        `json:"text,omitempty"`
	Keys           []string      `json:"keys,omitempty"`
	Reason         string        `json:"reason,omitempty"`
	SupersedesID   string        `json:"supersedes_event_id,omitempty"`
	SupersedesKind string        `json:"supersedes_kind,omitempty"`
	RequestID      string        `json:"request_id,omitempty"`
	Action         string        `json:"action,omitempty"`
}

// UnmarshalJSON accepts the canonical nested error object and normalizes the
// flattened backend-error records written by legacy engines. Marshal uses only
// the canonical nested representation.
func (event *Event) UnmarshalJSON(payload []byte) error {
	type eventAlias Event
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		return err
	}
	var wire struct {
		eventAlias
		LegacyClass          string `json:"error_class"`
		LegacyRetryable      *bool  `json:"retryable"`
		LegacySummary        string `json:"summary"`
		LegacyDetail         string `json:"detail"`
		LegacyBackendMode    string `json:"backend_mode"`
		LegacyBackendPath    string `json:"backend_path"`
		LegacyBackendVersion string `json:"backend_version"`
		LegacyStderrPath     string `json:"stderr_path"`
	}
	if err := json.Unmarshal(payload, &wire); err != nil {
		return err
	}
	*event = Event(wire.eventAlias)
	if err := ValidateSchemaVersion(event.SchemaVersion); err != nil {
		return err
	}
	if event.SchemaVersion == LegacySchemaVersion && event.Error == nil && wire.LegacyClass != "" {
		retryable := false
		if wire.LegacyRetryable != nil {
			retryable = *wire.LegacyRetryable
		}
		event.Error = &BackendError{
			Class:          wire.LegacyClass,
			Retryable:      retryable,
			Summary:        wire.LegacySummary,
			Detail:         wire.LegacyDetail,
			BackendMode:    wire.LegacyBackendMode,
			BackendPath:    wire.LegacyBackendPath,
			BackendVersion: wire.LegacyBackendVersion,
			StderrPath:     wire.LegacyStderrPath,
			Call:           event.Call,
		}
	}
	if event.SchemaVersion == CurrentSchemaVersion && event.Kind == "backend_error" {
		if err := validateCanonicalBackendError(raw, event.Error); err != nil {
			return err
		}
	}
	return nil
}

func validateCanonicalBackendError(raw map[string]json.RawMessage, backendError *BackendError) error {
	legacyFields := []string{
		"error_class", "retryable", "summary", "detail", "backend_mode",
		"backend_path", "backend_version", "stderr_path", "call",
	}
	for _, field := range legacyFields {
		if _, exists := raw[field]; exists {
			return fmt.Errorf("backend_error: canonical schema v1 cannot include legacy field %q", field)
		}
	}

	errorPayload, exists := raw["error"]
	if !exists || bytes.Equal(bytes.TrimSpace(errorPayload), []byte("null")) || backendError == nil {
		return fmt.Errorf("backend_error.error: canonical nested evidence is required")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(errorPayload, &fields); err != nil {
		return fmt.Errorf("backend_error.error: %w", err)
	}
	for _, field := range []string{
		"class", "code", "retryable", "summary", "detail", "backend_mode",
		"backend_path", "backend_version", "stderr_path", "call", "timestamp",
	} {
		if _, exists := fields[field]; !exists {
			return fmt.Errorf("backend_error.error.%s: required field is missing", field)
		}
	}
	if backendError.Class == "" {
		return fmt.Errorf("backend_error.error.class: must not be empty")
	}
	if backendError.Code == "" {
		return fmt.Errorf("backend_error.error.code: must not be empty")
	}
	if backendError.Summary == "" {
		return fmt.Errorf("backend_error.error.summary: must not be empty")
	}
	if backendError.Call < 0 {
		return fmt.Errorf("backend_error.error.call: must be non-negative")
	}
	if backendError.Timestamp == "" {
		return fmt.Errorf("backend_error.error.timestamp: must not be empty")
	}
	return nil
}

type Decision struct {
	Action     string   `json:"action"`
	Text       string   `json:"text"`
	Keys       []string `json:"keys"`
	Safe       bool     `json:"safe"`
	Reason     string   `json:"reason"`
	PaneState  string   `json:"pane_state,omitempty"`
	GoalStatus string   `json:"goal_status,omitempty"`
	Risk       string   `json:"risk,omitempty"`
	Evidence   []string `json:"evidence,omitempty"`
}

func (d Decision) Validate() error {
	if !oneOf(d.Action, "send", "wait", "done", "escalate", "suggest") {
		return fmt.Errorf("action: unsupported value %q", d.Action)
	}
	if d.Keys == nil {
		return fmt.Errorf("keys: required array is missing")
	}
	if d.PaneState != "" && !oneOf(d.PaneState, "working", "blocked", "idle", "done", "unknown") {
		return fmt.Errorf("pane_state: unsupported value %q", d.PaneState)
	}
	if d.GoalStatus != "" && !oneOf(d.GoalStatus, "working", "blocked", "done", "unclear") {
		return fmt.Errorf("goal_status: unsupported value %q", d.GoalStatus)
	}
	if d.Risk != "" && !oneOf(d.Risk, "low", "medium", "high", "unknown") {
		return fmt.Errorf("risk: unsupported value %q", d.Risk)
	}
	return nil
}

type DecisionMeta struct {
	SchemaVersion int     `json:"schema_version,omitempty"`
	RunID         string  `json:"run_id,omitempty"`
	Pane          string  `json:"pane,omitempty"`
	EventID       string  `json:"event_id,omitempty"`
	Call          int     `json:"call"`
	Backend       string  `json:"backend,omitempty"`
	Model         string  `json:"model,omitempty"`
	Profile       string  `json:"profile,omitempty"`
	Effort        string  `json:"effort,omitempty"`
	Autonomy      string  `json:"autonomy,omitempty"`
	Policy        string  `json:"policy,omitempty"`
	StartedAt     int64   `json:"started_at,omitempty"`
	Elapsed       float64 `json:"elapsed_seconds,omitempty"`
	Timeout       int     `json:"timeout_seconds,omitempty"`
	BackendRC     int     `json:"backend_rc,omitempty"`
	SchemaValid   bool    `json:"schema_valid"`
	SchemaError   string  `json:"schema_error,omitempty"`
	CompletedAt   string  `json:"completed_at,omitempty"`
}

type Final struct {
	SchemaVersion  int    `json:"schema_version,omitempty"`
	Outcome        string `json:"outcome"`
	Reason         string `json:"reason"`
	RunID          string `json:"run_id,omitempty"`
	Pane           string `json:"pane,omitempty"`
	Goal           string `json:"goal,omitempty"`
	GoalStatus     string `json:"goal_status,omitempty"`
	Duration       int64  `json:"duration_seconds,omitempty"`
	EventCount     int    `json:"event_count,omitempty"`
	DecisionCount  int    `json:"decision_count,omitempty"`
	ActionCount    int    `json:"action_count,omitempty"`
	ErrorCount     int    `json:"error_count,omitempty"`
	LogPath        string `json:"log_path,omitempty"`
	FinalizedAt    string `json:"finalized_at,omitempty"`
	FinalizedEpoch int64  `json:"finalized_epoch,omitempty"`
}

type BackendError struct {
	Class          string `json:"class"`
	Code           string `json:"code"`
	Retryable      bool   `json:"retryable"`
	Summary        string `json:"summary"`
	Detail         string `json:"detail"`
	BackendMode    string `json:"backend_mode"`
	BackendPath    string `json:"backend_path"`
	BackendVersion string `json:"backend_version"`
	StderrPath     string `json:"stderr_path"`
	EvidencePath   string `json:"evidence_path,omitempty"`
	Call           int    `json:"call"`
	Timestamp      string `json:"timestamp"`
}

type OwnerKind string

const (
	OwnerSplit    OwnerKind = "split"
	OwnerPopup    OwnerKind = "popup"
	OwnerDetached OwnerKind = "detached"
	OwnerViewer   OwnerKind = "viewer"
)

type OwnerDescriptor struct {
	SchemaVersion int       `json:"schema_version"`
	Kind          OwnerKind `json:"kind"`
	Pane          string    `json:"pane,omitempty"`
	PID           int       `json:"pid,omitempty"`
	Token         string    `json:"token,omitempty"`
	HeartbeatPath string    `json:"heartbeat_path,omitempty"`
}

type StartResult struct {
	ProtocolVersion int              `json:"protocol_version"`
	OK              bool             `json:"ok"`
	Status          string           `json:"status"`
	RunID           string           `json:"run_id,omitempty"`
	RunDir          string           `json:"run_dir,omitempty"`
	WatcherPID      int              `json:"watcher_pid,omitempty"`
	Owner           *OwnerDescriptor `json:"owner,omitempty"`
	Code            string           `json:"code,omitempty"`
	Error           *BackendError    `json:"error,omitempty"`
}

func ValidateSchemaVersion(version int) error {
	if version != LegacySchemaVersion && version != CurrentSchemaVersion {
		return fmt.Errorf("schema_version: unsupported version %d", version)
	}
	return nil
}

func oneOf(value string, allowed ...string) bool {
	for _, item := range allowed {
		if value == item {
			return true
		}
	}
	return false
}
