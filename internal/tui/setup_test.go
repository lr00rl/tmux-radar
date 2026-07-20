package tui

import (
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/preflight"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

func keyPress(code rune, text string, modifiers ...tea.KeyMod) tea.KeyPressMsg {
	var mod tea.KeyMod
	for _, value := range modifiers {
		mod |= value
	}
	return tea.KeyPressMsg(tea.Key{Code: code, Text: text, Mod: mod})
}

func updateSetup(t *testing.T, model SetupModel, msg tea.Msg) SetupModel {
	t.Helper()
	updated, _ := model.Update(msg)
	return updated
}

func setSetupInput(model *SetupModel, id, value string) {
	input := model.inputs[id]
	input.SetValue(value)
	model.inputs[id] = input
}

func compatiblePreflight() preflight.Result {
	return preflight.Result{
		OK: true,
		Backend: runmodel.BackendIdentity{
			Mode: "codex", Path: "/Users/test/bin/codex", Version: "0.144.4",
			Identity: "1:2:3:4", Source: "path", Model: "gpt-5.6-luna",
			Effort: "high", ModelSource: runmodel.SourceDefault,
			EffortSource: runmodel.SourceDefault, Compatible: true,
		},
		Model: "gpt-5.6-luna", Effort: "high",
	}
}

func readySetup(entry EntryMode) SetupModel {
	result := compatiblePreflight()
	return NewSetup(SetupOptions{TargetPane: "%42", Entry: entry, Preflight: &result})
}

func TestSetupInitialFocusAndCJKEditing(t *testing.T) {
	model := readySetup(EntryQuick)
	if model.focusedID() != fieldGoal || !model.editing {
		t.Fatalf("initial focus=%q editing=%v", model.focusedID(), model.editing)
	}
	model = updateSetup(t, model, keyPress('文', "AB中文"))
	model = updateSetup(t, model, keyPress(tea.KeyBackspace, ""))
	if got := model.goal.Value(); got != "AB中" {
		t.Fatalf("CJK backspace = %q want %q", got, "AB中")
	}

	model = updateSetup(t, model, keyPress(tea.KeyTab, ""))
	if model.focusedID() != fieldPreset || model.editing {
		t.Fatalf("Tab focus=%q editing=%v", model.focusedID(), model.editing)
	}
	model = updateSetup(t, model, keyPress(tea.KeyTab, "", tea.ModShift))
	if model.focusedID() != fieldGoal || !model.editing {
		t.Fatalf("Shift-Tab focus=%q editing=%v", model.focusedID(), model.editing)
	}
}

func TestSetupEnumToggleAndNumericValidation(t *testing.T) {
	model := readySetup(EntryQuick)
	model.setFocus(fieldPreset)
	model = updateSetup(t, model, keyPress(tea.KeyRight, ""))
	if model.preset != PresetCautious || model.config.Values.ApprovalPolicy.Value != "manual" ||
		model.config.Values.Autonomy.Value != "confirm" {
		t.Fatalf("cautious preset not applied: preset=%q config=%#v", model.preset, model.config.Values)
	}
	model.setFocus(fieldApproval)
	model = updateSetup(t, model, keyPress(tea.KeyRight, ""))
	if model.config.Values.ApprovalPolicy.Value != "always-allow" ||
		model.config.Values.ApprovalPolicy.Source != runmodel.SourceCustom {
		t.Fatalf("policy selector=%#v", model.config.Values.ApprovalPolicy)
	}
	model.setFocus(fieldAutonomy)
	model = updateSetup(t, model, keyPress(tea.KeyLeft, ""))
	if model.config.Values.Autonomy.Value != "suggest" ||
		model.config.Values.Autonomy.Source != runmodel.SourceCustom {
		t.Fatalf("autonomy selector=%#v", model.config.Values.Autonomy)
	}

	model.advanced = true
	model.groups[groupTriggering] = true
	model.rebuildFocus()
	model.setFocus(fieldHooksFirst)
	model = updateSetup(t, model, keyPress(tea.KeySpace, " "))
	if model.config.Values.HooksFirst.Value != "off" || model.config.Values.HooksFirst.Source != runmodel.SourceCustom {
		t.Fatalf("hooks toggle=%#v", model.config.Values.HooksFirst)
	}
	model.setFocus(fieldPoll)
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	setSetupInput(&model, fieldPoll, "10.5")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if !model.editing || model.errors[fieldPoll] == "" || model.config.Values.Poll.Value != 5 {
		t.Fatalf("fractional poll accepted: editing=%v error=%q poll=%g", model.editing,
			model.errors[fieldPoll], model.config.Values.Poll.Value)
	}
	setSetupInput(&model, fieldPoll, "10")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if model.editing || model.errors[fieldPoll] != "" || model.config.Values.Poll.Value != 10 ||
		model.config.Values.Poll.Source != runmodel.SourceCustom {
		t.Fatalf("whole-second poll rejected: editing=%v error=%q poll=%#v", model.editing,
			model.errors[fieldPoll], model.config.Values.Poll)
	}

	model.groups[groupBrain] = true
	model.rebuildFocus()
	model.setFocus(fieldTimeout)
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	setSetupInput(&model, fieldTimeout, "4")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if !model.editing || model.errors[fieldTimeout] == "" || model.config.Values.Timeout.Value != 120 {
		t.Fatalf("invalid timeout accepted: editing=%v error=%q timeout=%d", model.editing,
			model.errors[fieldTimeout], model.config.Values.Timeout.Value)
	}
	setSetupInput(&model, fieldTimeout, "60")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if model.editing || model.errors[fieldTimeout] != "" || model.config.Values.Timeout.Value != 60 ||
		model.config.Values.Timeout.Source != runmodel.SourceCustom {
		t.Fatalf("valid timeout rejected: editing=%v error=%q timeout=%#v", model.editing,
			model.errors[fieldTimeout], model.config.Values.Timeout)
	}

	model.groups[groupContext] = true
	model.rebuildFocus()
	model.setFocus(fieldFallbackCapture)
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	setSetupInput(&model, fieldFallbackCapture, "7")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if !model.editing || model.errors[fieldFallbackCapture] == "" ||
		model.config.Values.FallbackCaptureLines.Value != 20 {
		t.Fatalf("invalid fallback capture accepted: editing=%v error=%q lines=%d", model.editing,
			model.errors[fieldFallbackCapture], model.config.Values.FallbackCaptureLines.Value)
	}
	setSetupInput(&model, fieldFallbackCapture, "19")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if model.editing || model.errors[fieldFallbackCapture] != "" ||
		model.config.Values.FallbackCaptureLines != (runmodel.Value[int]{Value: 19, Source: runmodel.SourceCustom}) {
		t.Fatalf("valid fallback capture rejected: editing=%v error=%q lines=%#v", model.editing,
			model.errors[fieldFallbackCapture], model.config.Values.FallbackCaptureLines)
	}
}

func TestSetupAdvancedCountsAndEntryModes(t *testing.T) {
	base := runmodel.DefaultConfig("%42", "")
	base.Values.Timeout.Source = runmodel.SourceTMUX
	base.Values.Logging = runmodel.Value[string]{Value: "full", Source: runmodel.SourceCustom}
	result := compatiblePreflight()
	model := NewSetup(SetupOptions{TargetPane: "%42", Entry: EntryQuick, Config: &base, Preflight: &result})
	changed, inherited := model.advancedCounts()
	if changed != 1 || inherited != 1 {
		t.Fatalf("advanced counts=(%d,%d) want (1,1)", changed, inherited)
	}

	quick := readySetup(EntryQuick)
	if quick.advanced || quick.preset != PresetDefault || quick.config.Values.ApprovalPolicy.Value != "safe-auto" {
		t.Fatalf("quick entry=%#v", quick)
	}
	allow := readySetup(EntryAlwaysAllow)
	if allow.advanced || allow.preset != PresetAlwaysAllow ||
		allow.config.Values.ApprovalPolicy.Value != "always-allow" ||
		allow.config.Values.AlwaysAllow.Value != "on" {
		t.Fatalf("always-allow entry=%#v", allow.config.Values)
	}
	advanced := readySetup(EntryAdvanced)
	if !advanced.advanced || advanced.preset != PresetDefault {
		t.Fatalf("advanced entry: advanced=%v preset=%q", advanced.advanced, advanced.preset)
	}
	for _, group := range advancedGroupOrder {
		if !advanced.groups[group] {
			t.Fatalf("advanced entry left group %q collapsed", group)
		}
	}
}

func TestSetupCancellationAndLaunchBlocking(t *testing.T) {
	model := NewSetup(SetupOptions{TargetPane: "%42", Entry: EntryQuick})
	model.setFocus(fieldStart)
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if model.launchRequested || !strings.Contains(model.blockingError, "Preflight") {
		t.Fatalf("pending preflight launch: requested=%v error=%q", model.launchRequested, model.blockingError)
	}

	requestID := model.beginPreflight()
	model = updateSetup(t, model, PreflightResultMsg{RequestID: requestID - 1, Result: compatiblePreflight()})
	if model.preflightStatus != preflightPending {
		t.Fatalf("stale preflight result changed status to %q", model.preflightStatus)
	}
	model = updateSetup(t, model, PreflightResultMsg{RequestID: requestID, Result: compatiblePreflight()})
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	if !model.launchRequested || model.blockingError != "" {
		t.Fatalf("ready launch: requested=%v error=%q", model.launchRequested, model.blockingError)
	}

	cancel := readySetup(EntryQuick)
	cancel.setFocus(fieldPreset)
	cancel = updateSetup(t, cancel, keyPress('q', "q"))
	if !cancel.cancelled {
		t.Fatal("q outside an editor did not cancel setup")
	}
}

func TestSetupProducesExactImmutableConfig(t *testing.T) {
	model := readySetup(EntryAlwaysAllow)
	goal := "  允许所有安全操作\n直到任务全部完成  "
	model = updateSetup(t, model, tea.PasteMsg{Content: goal})
	model.advanced = true
	model.groups[groupTriggering] = true
	model.rebuildFocus()
	model.setFocus(fieldPoll)
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))
	setSetupInput(&model, fieldPoll, "10")
	model = updateSetup(t, model, keyPress(tea.KeyEnter, ""))

	config, err := model.immutableConfig()
	if err != nil {
		t.Fatal(err)
	}
	want := runmodel.DefaultConfig("%42", goal)
	want.Values.ApprovalPolicy = runmodel.Value[string]{Value: "always-allow", Source: runmodel.SourcePreset}
	want.Values.AlwaysAllow = runmodel.Value[string]{Value: "on", Source: runmodel.SourcePreset}
	want.Values.Autonomy = runmodel.Value[string]{Value: "auto-safe", Source: runmodel.SourcePreset}
	want.Values.Poll = runmodel.Value[float64]{Value: 10, Source: runmodel.SourceCustom}
	backend := compatiblePreflight().Backend
	want.Backend = &backend
	if !reflect.DeepEqual(config, want) {
		t.Fatalf("immutable config mismatch\n got: %#v\nwant: %#v", config, want)
	}
	if config.Goal != goal || config.Values.Goal.Value != goal {
		t.Fatalf("goal bytes changed: top=%q value=%q", config.Goal, config.Values.Goal.Value)
	}
}

func TestSetupReviewsLoadedTmuxModelAndProvenance(t *testing.T) {
	base := runmodel.DefaultConfig("%145", "")
	base.Values.Model = runmodel.Value[string]{
		Value: "gpt-5.3-codex-spark", Source: runmodel.SourceTMUX,
	}
	result := compatiblePreflight()
	result.Model = base.Values.Model.Value
	result.Backend.Model = base.Values.Model.Value
	result.Backend.ModelSource = runmodel.SourceTMUX

	model := NewSetup(SetupOptions{
		TargetPane: "%145", Entry: EntryAlwaysAllow, Config: &base, Preflight: &result,
	})
	if !strings.Contains(model.View(), "Brain gpt-5.3-codex-spark/high") {
		t.Fatalf("setup did not show loaded tmux model:\n%s", model.View())
	}
	config, err := model.immutableConfig()
	if err != nil {
		t.Fatal(err)
	}
	if config.Values.Model.Source != runmodel.SourceTMUX ||
		config.Backend == nil || config.Backend.ModelSource != runmodel.SourceTMUX {
		t.Fatalf("reviewed provenance was not preserved: config=%#v", config)
	}
}

func TestSetupProfileManagesOnlyImplicitBrainFields(t *testing.T) {
	model := readySetup(EntryAdvanced)
	model.setTextField(fieldProfile, "locked")
	if model.config.Values.Model != (runmodel.Value[string]{Source: runmodel.SourceProfileManaged}) ||
		model.config.Values.Effort != (runmodel.Value[string]{Source: runmodel.SourceProfileManaged}) {
		t.Fatalf("profile retained false built-in defaults: model=%#v effort=%#v",
			model.config.Values.Model, model.config.Values.Effort)
	}
	model.setTextField(fieldProfile, "")
	if model.config.Values.Model != (runmodel.Value[string]{
		Value: "gpt-5.6-luna", Source: runmodel.SourceDefault,
	}) || model.config.Values.Effort != (runmodel.Value[string]{
		Value: "high", Source: runmodel.SourceDefault,
	}) {
		t.Fatalf("clearing profile did not restore defaults: model=%#v effort=%#v",
			model.config.Values.Model, model.config.Values.Effort)
	}

	base := runmodel.DefaultConfig("%145", "")
	base.Values.Model = runmodel.Value[string]{
		Value: "gpt-5.3-codex-spark", Source: runmodel.SourceTMUX,
	}
	model = NewSetup(SetupOptions{TargetPane: "%145", Entry: EntryAdvanced, Config: &base})
	model.setTextField(fieldProfile, "locked")
	if model.config.Values.Model != base.Values.Model {
		t.Fatalf("profile replaced explicit tmux model: got=%#v want=%#v",
			model.config.Values.Model, base.Values.Model)
	}
	if model.config.Values.Effort.Source != runmodel.SourceProfileManaged {
		t.Fatalf("profile falsely retained implicit effort: %#v", model.config.Values.Effort)
	}

	model.setTextField(fieldModel, "explicit-model")
	model.setTextField(fieldModel, "")
	if model.config.Values.Model != (runmodel.Value[string]{Source: runmodel.SourceProfileManaged}) {
		t.Fatalf("clearing an explicit model did not restore profile management: %#v",
			model.config.Values.Model)
	}
	if _, err := model.reviewedConfig(); err != nil {
		t.Fatalf("restored profile-managed model is not reviewable: %v", err)
	}
}
