package tui

import (
	"strconv"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

type EntryMode string

const (
	EntryQuick       EntryMode = "quick"
	EntryAlwaysAllow EntryMode = "always-allow"
	EntryAdvanced    EntryMode = "advanced"
)

type Preset string

const (
	PresetDefault     Preset = "Default"
	PresetCautious    Preset = "Cautious"
	PresetAlwaysAllow Preset = "Always allow"
)

const (
	fieldGoal       = "goal"
	fieldPreset     = "preset"
	fieldApproval   = "approval_policy"
	fieldAutonomy   = "autonomy"
	fieldAdvanced   = "advanced"
	fieldStart      = "start"
	fieldAlways     = "always_allow"
	fieldHooksFirst = "hooks_first"
	fieldPoll       = "poll"
	fieldStable     = "stable_screen_threshold"
	fieldCommand    = "command"
	fieldProfile    = "profile"
	fieldModel      = "model"
	fieldEffort     = "effort"
	fieldTimeout    = "timeout"
	fieldMaxCalls   = "max_decisions"
	fieldRetryLimit = "retry_limit"
	fieldRetryBack  = "retry_backoff"
	fieldCapture    = "capture_lines"
	fieldExcerpt    = "monitor_excerpt_lines"
	fieldPosition   = "monitor_position"
	fieldWidth      = "monitor_width"
	fieldRatio      = "overview_ratio"
	fieldCloseDelay = "completion_close_delay"
	fieldLogging    = "logging"
	fieldSnapshots  = "screen_snapshots"
	fieldRetention  = "retention_days"
)

const (
	groupIntent     = "Intent"
	groupAuthority  = "Authority"
	groupTriggering = "Triggering"
	groupBrain      = "Brain"
	groupBudget     = "Budget"
	groupContext    = "Context"
	groupConsole    = "Console"
	groupLogging    = "Logging"
)

var advancedGroupOrder = []string{
	groupIntent, groupAuthority, groupTriggering, groupBrain,
	groupBudget, groupContext, groupConsole, groupLogging,
}

type fieldKind int

const (
	kindText fieldKind = iota
	kindInt
	kindFloat
	kindEnum
	kindToggle
)

type fieldSpec struct {
	ID      string
	Label   string
	Group   string
	Kind    fieldKind
	Options []string
	Min     float64
	Max     float64
}

var advancedFields = []fieldSpec{
	{ID: fieldAlways, Label: "Always allow", Group: groupAuthority, Kind: kindToggle},
	{ID: fieldHooksFirst, Label: "Hooks first", Group: groupTriggering, Kind: kindToggle},
	{ID: fieldPoll, Label: "Idle interval", Group: groupTriggering, Kind: kindFloat, Min: 0.05, Max: 3600},
	{ID: fieldStable, Label: "Stable samples", Group: groupTriggering, Kind: kindInt, Min: 1, Max: 20},
	{ID: fieldCommand, Label: "Command", Group: groupBrain, Kind: kindText},
	{ID: fieldProfile, Label: "Profile", Group: groupBrain, Kind: kindText},
	{ID: fieldModel, Label: "Model", Group: groupBrain, Kind: kindText},
	{ID: fieldEffort, Label: "Effort", Group: groupBrain, Kind: kindEnum, Options: []string{"minimal", "low", "medium", "high", "xhigh"}},
	{ID: fieldTimeout, Label: "Timeout", Group: groupBrain, Kind: kindInt, Min: 5, Max: 3600},
	{ID: fieldMaxCalls, Label: "Decision limit", Group: groupBudget, Kind: kindInt, Min: 1, Max: 10000},
	{ID: fieldRetryLimit, Label: "Retry limit", Group: groupBudget, Kind: kindInt, Min: 0, Max: 10},
	{ID: fieldRetryBack, Label: "Retry backoff", Group: groupBudget, Kind: kindInt, Min: 0, Max: 3600},
	{ID: fieldCapture, Label: "Capture lines", Group: groupContext, Kind: kindInt, Min: 20, Max: 5000},
	{ID: fieldExcerpt, Label: "Screen excerpt", Group: groupContext, Kind: kindInt, Min: 3, Max: 500},
	{ID: fieldPosition, Label: "Monitor position", Group: groupConsole, Kind: kindEnum, Options: []string{"right", "top", "bottom"}},
	{ID: fieldWidth, Label: "Monitor width", Group: groupConsole, Kind: kindInt, Min: 20, Max: 240},
	{ID: fieldRatio, Label: "Overview ratio", Group: groupConsole, Kind: kindInt, Min: 15, Max: 50},
	{ID: fieldCloseDelay, Label: "Close delay", Group: groupConsole, Kind: kindInt, Min: 0, Max: 60},
	{ID: fieldLogging, Label: "Logging", Group: groupLogging, Kind: kindEnum, Options: []string{"decision", "full"}},
	{ID: fieldSnapshots, Label: "Screen snapshots", Group: groupLogging, Kind: kindToggle},
	{ID: fieldRetention, Label: "Retention days", Group: groupLogging, Kind: kindInt, Min: 0, Max: 3650},
}

func (model *SetupModel) cyclePreset(direction int) {
	options := []Preset{PresetDefault, PresetCautious, PresetAlwaysAllow}
	index := (indexOf(options, model.preset) + direction + len(options)) % len(options)
	model.preset = options[index]
	model.applyPreset(model.preset, false)
}

func (model *SetupModel) cycleBasicField(id string, direction int) {
	var options []string
	var current string
	switch id {
	case fieldApproval:
		options = []string{"safe-auto", "manual", "always-allow"}
		current = model.config.Values.ApprovalPolicy.Value
	case fieldAutonomy:
		options = []string{"suggest", "confirm", "auto-safe", "auto"}
		current = model.config.Values.Autonomy.Value
	default:
		return
	}
	value := options[(indexOf(options, current)+direction+len(options))%len(options)]
	custom := runmodel.Value[string]{Value: value, Source: runmodel.SourceCustom}
	if id == fieldApproval {
		model.config.Values.ApprovalPolicy = custom
	} else {
		model.config.Values.Autonomy = custom
	}
	model.launchRequested = false
}

func (model *SetupModel) applyPreset(preset Preset, initial bool) {
	source := runmodel.SourcePreset
	if initial && preset == PresetDefault {
		source = runmodel.SourceDefault
	}
	set := func(policy, autonomy, always string) {
		model.config.Values.ApprovalPolicy = runmodel.Value[string]{Value: policy, Source: source}
		model.config.Values.Autonomy = runmodel.Value[string]{Value: autonomy, Source: source}
		model.config.Values.AlwaysAllow = runmodel.Value[string]{Value: always, Source: source}
	}
	switch preset {
	case PresetCautious:
		set("manual", "confirm", "off")
	case PresetAlwaysAllow:
		set("always-allow", "auto-safe", "on")
	default:
		set("safe-auto", "auto-safe", "off")
	}
	model.launchRequested = false
}

func (model *SetupModel) cycleField(spec fieldSpec, direction int) {
	index := (indexOf(spec.Options, model.fieldValue(spec.ID)) + direction + len(spec.Options)) % len(spec.Options)
	value := spec.Options[index]
	switch spec.ID {
	case fieldEffort:
		model.config.Values.Effort = runmodel.Value[string]{Value: value, Source: runmodel.SourceCustom}
		model.beginPreflight()
	case fieldPosition:
		model.config.Values.MonitorPosition = runmodel.Value[string]{Value: value, Source: runmodel.SourceCustom}
	case fieldLogging:
		model.config.Values.Logging = runmodel.Value[string]{Value: value, Source: runmodel.SourceCustom}
	}
	model.launchRequested = false
}

func (model *SetupModel) toggleField(id string) {
	toggle := func(value runmodel.Value[string]) runmodel.Value[string] {
		if value.Value == "on" {
			return runmodel.Value[string]{Value: "off", Source: runmodel.SourceCustom}
		}
		return runmodel.Value[string]{Value: "on", Source: runmodel.SourceCustom}
	}
	switch id {
	case fieldAlways:
		model.config.Values.AlwaysAllow = toggle(model.config.Values.AlwaysAllow)
	case fieldHooksFirst:
		model.config.Values.HooksFirst = toggle(model.config.Values.HooksFirst)
	case fieldSnapshots:
		model.config.Values.ScreenSnapshots = toggle(model.config.Values.ScreenSnapshots)
	}
	model.launchRequested = false
}

func (model *SetupModel) setTextField(id, value string) {
	custom := runmodel.Value[string]{Value: value, Source: runmodel.SourceCustom}
	switch id {
	case fieldCommand:
		model.config.Values.Command = custom
	case fieldProfile:
		model.config.Values.Profile = custom
	case fieldModel:
		model.config.Values.Model = custom
	}
}

func (model *SetupModel) setIntField(id string, value int) {
	custom := runmodel.Value[int]{Value: value, Source: runmodel.SourceCustom}
	switch id {
	case fieldStable:
		model.config.Values.StableScreenThreshold = custom
	case fieldTimeout:
		model.config.Values.Timeout = custom
	case fieldMaxCalls:
		model.config.Values.MaxDecisions = custom
	case fieldRetryLimit:
		model.config.Values.RetryLimit = custom
	case fieldRetryBack:
		model.config.Values.RetryBackoff = custom
	case fieldCapture:
		model.config.Values.CaptureLines = custom
	case fieldExcerpt:
		model.config.Values.MonitorExcerptLines = custom
	case fieldWidth:
		model.config.Values.MonitorWidth = custom
	case fieldRatio:
		model.config.Values.OverviewRatio = custom
	case fieldCloseDelay:
		model.config.Values.CompletionCloseDelay = custom
	case fieldRetention:
		model.config.Values.RetentionDays = custom
	}
}

func (model SetupModel) fieldValue(id string) string {
	v := model.config.Values
	switch id {
	case fieldApproval:
		return v.ApprovalPolicy.Value
	case fieldAutonomy:
		return v.Autonomy.Value
	case fieldAlways:
		return v.AlwaysAllow.Value
	case fieldHooksFirst:
		return v.HooksFirst.Value
	case fieldPoll:
		return strconv.FormatFloat(v.Poll.Value, 'f', -1, 64)
	case fieldStable:
		return strconv.Itoa(v.StableScreenThreshold.Value)
	case fieldCommand:
		return v.Command.Value
	case fieldProfile:
		return v.Profile.Value
	case fieldModel:
		return v.Model.Value
	case fieldEffort:
		return v.Effort.Value
	case fieldTimeout:
		return strconv.Itoa(v.Timeout.Value)
	case fieldMaxCalls:
		return strconv.Itoa(v.MaxDecisions.Value)
	case fieldRetryLimit:
		return strconv.Itoa(v.RetryLimit.Value)
	case fieldRetryBack:
		return strconv.Itoa(v.RetryBackoff.Value)
	case fieldCapture:
		return strconv.Itoa(v.CaptureLines.Value)
	case fieldExcerpt:
		return strconv.Itoa(v.MonitorExcerptLines.Value)
	case fieldPosition:
		return v.MonitorPosition.Value
	case fieldWidth:
		return strconv.Itoa(v.MonitorWidth.Value)
	case fieldRatio:
		return strconv.Itoa(v.OverviewRatio.Value)
	case fieldCloseDelay:
		return strconv.Itoa(v.CompletionCloseDelay.Value)
	case fieldLogging:
		return v.Logging.Value
	case fieldSnapshots:
		return v.ScreenSnapshots.Value
	case fieldRetention:
		return strconv.Itoa(v.RetentionDays.Value)
	default:
		return ""
	}
}

func (model SetupModel) fieldSource(id string) runmodel.Source {
	v := model.config.Values
	switch id {
	case fieldAlways:
		return v.AlwaysAllow.Source
	case fieldHooksFirst:
		return v.HooksFirst.Source
	case fieldPoll:
		return v.Poll.Source
	case fieldStable:
		return v.StableScreenThreshold.Source
	case fieldCommand:
		return v.Command.Source
	case fieldProfile:
		return v.Profile.Source
	case fieldModel:
		return v.Model.Source
	case fieldEffort:
		return v.Effort.Source
	case fieldTimeout:
		return v.Timeout.Source
	case fieldMaxCalls:
		return v.MaxDecisions.Source
	case fieldRetryLimit:
		return v.RetryLimit.Source
	case fieldRetryBack:
		return v.RetryBackoff.Source
	case fieldCapture:
		return v.CaptureLines.Source
	case fieldExcerpt:
		return v.MonitorExcerptLines.Source
	case fieldPosition:
		return v.MonitorPosition.Source
	case fieldWidth:
		return v.MonitorWidth.Source
	case fieldRatio:
		return v.OverviewRatio.Source
	case fieldCloseDelay:
		return v.CompletionCloseDelay.Source
	case fieldLogging:
		return v.Logging.Source
	case fieldSnapshots:
		return v.ScreenSnapshots.Source
	case fieldRetention:
		return v.RetentionDays.Source
	default:
		return runmodel.SourceDefault
	}
}

func (model SetupModel) advancedCounts() (changed, inherited int) {
	for _, spec := range advancedFields {
		switch model.fieldSource(spec.ID) {
		case runmodel.SourceTMUX:
			inherited++
		case runmodel.SourceDefault:
		default:
			changed++
		}
	}
	return changed, inherited
}

func fieldByID(id string) (fieldSpec, bool) {
	for _, spec := range advancedFields {
		if spec.ID == id {
			return spec, true
		}
	}
	return fieldSpec{}, false
}

func indexOf[T comparable](values []T, target T) int {
	for index, value := range values {
		if value == target {
			return index
		}
	}
	return 0
}
