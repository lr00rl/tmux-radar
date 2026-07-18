package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/lr00rl/tmux-radar/internal/enginebridge"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

type fakeController struct {
	result enginebridge.ControlResult
	err    error
	calls  []string
}

func (controller *fakeController) Control(_ context.Context, runID, pane, action, requestID string) (enginebridge.ControlResult, error) {
	controller.calls = append(controller.calls, strings.Join([]string{runID, pane, action, requestID}, "|"))
	result := controller.result
	result.ProtocolVersion = 1
	result.SchemaVersion = 1
	result.RunID = runID
	result.Pane = pane
	result.Action = action
	result.RequestID = requestID
	if result.Status == "" {
		result.OK = true
		result.Status = "acknowledged"
	}
	return result, controller.err
}

func writeRunConfig(t *testing.T, dir string, config runmodel.Config) {
	t.Helper()
	payload, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.json"), append(payload, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func newLiveFixture(t *testing.T, surface Surface) (LiveModel, *fakeController) {
	t.Helper()
	dir := t.TempDir()
	config := runmodel.DefaultConfig("%42", "live console goal")
	writeRunConfig(t, dir, config)
	reader, err := runmodel.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	controller := &fakeController{}
	sequence := 0
	model, err := NewLive(LiveOptions{
		RunDir: dir, RunID: "run-1", Reader: reader, Controller: controller,
		Surface: surface, RequestID: func() string {
			sequence++
			return fmt.Sprintf("req-%d", sequence)
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	model.resize(72, 24)
	model.applyRunUpdate(runPollMsg{Snapshot: runmodel.Snapshot{
		Config: config,
		State:  &runmodel.State{SchemaVersion: 1, Phase: "ARMED", Status: "waiting", RunID: "run-1", Pane: "%42", MaxCalls: 40},
	}, SnapshotChanged: true})
	return model, controller
}

func makeEvents(count int, kind, label string) []runmodel.Event {
	events := make([]runmodel.Event, count)
	for index := range events {
		events[index] = runmodel.Event{
			SchemaVersion: 1, Kind: kind, Label: label, Source: "watcher",
			Timestamp: fmt.Sprintf("2026-07-16T12:%02d:%02dZ", index/60, index%60),
			EventID:   fmt.Sprintf("event-%d", index),
		}
	}
	return events
}

func TestLiveSwitchesFiveViewsAndRendersCanonicalEvidence(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	model.details = runDetails{
		Decision: &runmodel.Decision{Action: "send", Text: "2", Keys: []string{"Enter"}, Safe: true,
			Reason: "approval is narrow", PaneState: "blocked", GoalStatus: "working", Risk: "low",
			Evidence: []string{"approval prompt visible"}},
		DecisionMeta: &runmodel.DecisionMeta{SchemaVersion: 1, Call: 2, Model: "gpt-5.6-luna", Effort: "high", Elapsed: 4.2},
		Screen:       "last target line\napproval prompt", ScreenPath: "/tmp/screens/0002.txt",
		Stderr: "backend detail", StderrPath: "/tmp/backend/0002.stderr",
	}
	model.events = append(model.events, makeEvents(1, "model_finished", "model call finished")...)
	model.rebuildGroups()
	for index, expected := range []string{"model call finished", "approval is narrow", "approval prompt", "Approval policy", "backend detail"} {
		model = updateLive(t, model, keyPress(rune('1'+index), string(rune('1'+index))))
		view := ansi.Strip(model.View())
		if model.activeView != LiveView(index) || !strings.Contains(view, expected) {
			t.Fatalf("view %d missing %q\n%s", index+1, expected, view)
		}
		if strings.Contains(strings.ToLower(view), "chain-of-thought") || strings.Contains(strings.ToLower(view), "private reasoning") {
			t.Fatalf("view %d labels private reasoning\n%s", index+1, view)
		}
	}
}

func updateLive(t *testing.T, model LiveModel, message tea.Msg) LiveModel {
	t.Helper()
	updated, _ := model.Update(message)
	return updated
}

func TestTimelineGroupsEventsAndExpansionIsPresentationOnly(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	model.applyRunUpdate(runPollMsg{Events: makeEvents(3, "ARMED", "waiting")})
	if len(model.groups) != 1 || model.groups[0].Count != 3 || model.groups[0].Expanded {
		t.Fatalf("groups=%#v", model.groups)
	}
	before := append([]runmodel.Event(nil), model.events...)
	model = updateLive(t, model, keyPress('e', "e"))
	if !model.groups[0].Expanded || !strings.Contains(ansi.Strip(model.View()), "#3") {
		t.Fatalf("expanded timeline missing raw members\n%s", ansi.Strip(model.View()))
	}
	if len(model.events) != len(before) || model.events[0].EventID != before[0].EventID {
		t.Fatal("timeline expansion mutated canonical events")
	}
}

func TestTimelinePinsScrollAndCountsNewEventsUntilG(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	model.resize(56, 16)
	for index := 0; index < 24; index++ {
		model.applyRunUpdate(runPollMsg{Events: makeEvents(1, fmt.Sprintf("kind-%02d", index), fmt.Sprintf("event %02d", index))})
	}
	model.viewport.GotoBottom()
	model.timelineFollow = true
	bottom := model.viewport.YOffset()
	model = updateLive(t, model, keyPress('k', "k"))
	if model.timelineFollow || model.viewport.YOffset() >= bottom {
		t.Fatalf("scroll up did not pin timeline: follow=%v y=%d bottom=%d", model.timelineFollow, model.viewport.YOffset(), bottom)
	}
	pinned := model.viewport.YOffset()
	model.applyRunUpdate(runPollMsg{Events: makeEvents(1, "new-kind", "new event")})
	if model.viewport.YOffset() != pinned || model.newEvents != 1 {
		t.Fatalf("pinned timeline moved: y=%d want=%d new=%d", model.viewport.YOffset(), pinned, model.newEvents)
	}
	model = updateLive(t, model, keyPress('G', "G"))
	if !model.timelineFollow || model.newEvents != 0 || !model.viewport.AtBottom() {
		t.Fatalf("G did not resume follow: follow=%v new=%d bottom=%v", model.timelineFollow, model.newEvents, model.viewport.AtBottom())
	}
}

func TestLiveControlShowsPendingThenCanonicalAckOrError(t *testing.T) {
	model, controller := newLiveFixture(t, SurfaceSplit)
	updated, command := model.Update(keyPress('p', "p"))
	model = updated
	if model.pending == nil || model.pending.Action != "pause" || command == nil {
		t.Fatalf("pause pending=%#v command=%v", model.pending, command)
	}
	message := command()
	model = updateLive(t, model, message)
	if model.pending != nil || !strings.Contains(model.controlNotice, "acknowledged") || len(controller.calls) != 1 {
		t.Fatalf("pause acknowledgement pending=%#v notice=%q calls=%#v", model.pending, model.controlNotice, controller.calls)
	}

	controller.err = errors.New("bridge unavailable")
	updated, command = model.Update(keyPress('r', "r"))
	model = updated
	model = updateLive(t, model, command())
	if model.pending != nil || !strings.Contains(model.controlError, "bridge unavailable") {
		t.Fatalf("control error pending=%#v error=%q", model.pending, model.controlError)
	}

	controller.err = nil
	updated, command = model.Update(keyPress('p', "p"))
	model = updated
	mismatch := command().(controlResultMsg)
	mismatch.Result.RequestID = "wrong-request"
	model = updateLive(t, model, mismatch)
	if model.pending != nil || !strings.Contains(model.controlError, "identity") {
		t.Fatalf("mismatched acknowledgement was accepted: pending=%#v error=%q", model.pending, model.controlError)
	}
}

func TestLivePermanentErrorCompletionKeepAndHelp(t *testing.T) {
	model, controller := newLiveFixture(t, SurfaceSplit)
	backendError := &runmodel.BackendError{
		Class: "config-permanent", Code: "codex-too-old", Summary: "Codex is too old",
		Detail: "upgrade the selected binary", BackendMode: "codex", BackendPath: "/old/codex",
		BackendVersion: "0.139.0", StderrPath: "/tmp/backend/0001.stderr", Call: 1,
		Timestamp: "2026-07-16T12:00:00Z",
	}
	model.applyRunUpdate(runPollMsg{Events: []runmodel.Event{{
		SchemaVersion: 1, Kind: "backend_error", Source: "watcher", Label: "backend failed", Error: backendError,
	}}})
	if view := ansi.Strip(model.View()); !strings.Contains(view, "Codex is too old") || !strings.Contains(view, "PERMANENT") {
		t.Fatalf("permanent error is not explicit\n%s", view)
	}

	model.snapshot.Final = &runmodel.Final{SchemaVersion: 1, Outcome: "completed", Reason: "goal done"}
	updated, command := model.Update(keyPress('k', "k"))
	model = updated
	if command == nil || model.pending == nil || model.pending.Action != "keep" {
		t.Fatalf("completion keep pending=%#v", model.pending)
	}
	model = updateLive(t, model, command())
	if len(controller.calls) == 0 || !strings.Contains(controller.calls[len(controller.calls)-1], "|keep|") {
		t.Fatalf("keep control calls=%#v", controller.calls)
	}

	model = updateLive(t, model, keyPress('?', "?"))
	if !model.showHelp || !strings.Contains(ansi.Strip(model.View()), "Live controls") {
		t.Fatalf("help overlay missing\n%s", ansi.Strip(model.View()))
	}
}

func TestLiveActiveStopRequiresConfirmation(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	updated, command := model.Update(keyPress('q', "q"))
	model = updated
	if !model.confirmStop || command != nil || model.pending != nil {
		t.Fatalf("first q stopped immediately: confirm=%v pending=%#v", model.confirmStop, model.pending)
	}
	updated, command = model.Update(keyPress('y', "y"))
	model = updated
	if command == nil || model.pending == nil || model.pending.Action != "stop" {
		t.Fatalf("confirmed stop missing: pending=%#v", model.pending)
	}
}

func TestLiveCompletionTimerClosesConsoleAndOwnerSurface(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	config := model.snapshot.Config
	config.Values.CompletionCloseDelay = runmodel.Value[int]{Value: 0, Source: runmodel.SourceCustom}
	final := &runmodel.Final{SchemaVersion: 1, Outcome: "completed", Reason: "goal done", RunID: "run-1", Pane: "%42"}
	updated, command := model.Update(runPollMsg{Snapshot: runmodel.Snapshot{Config: config, Final: final}, SnapshotChanged: true})
	model = updated
	if command == nil || model.closed {
		t.Fatalf("completion timer command=%v closed=%v", command, model.closed)
	}
	updated, quit := model.Update(command())
	model = updated
	if !model.closed || quit == nil {
		t.Fatalf("completion auto-close: closed=%v quit=%v", model.closed, quit)
	}
}

func TestLiveKeepInvalidatesPendingCompletionTimer(t *testing.T) {
	model, controller := newLiveFixture(t, SurfaceSplit)
	config := model.snapshot.Config
	config.Values.CompletionCloseDelay = runmodel.Value[int]{Value: 0, Source: runmodel.SourceCustom}
	final := &runmodel.Final{SchemaVersion: 1, Outcome: "completed", Reason: "goal done", RunID: "run-1", Pane: "%42"}
	updated, closeCommand := model.Update(runPollMsg{Snapshot: runmodel.Snapshot{Config: config, Final: final}, SnapshotChanged: true})
	model = updated
	updated, keepCommand := model.Update(keyPress('k', "k"))
	model = updated
	if keepCommand == nil || !model.completionKept {
		t.Fatalf("keep did not hold completion: command=%v kept=%v", keepCommand, model.completionKept)
	}
	model = updateLive(t, model, closeCommand())
	if model.closed {
		t.Fatal("stale completion timer closed a kept report")
	}
	model = updateLive(t, model, keepCommand())
	if len(controller.calls) == 0 || !strings.Contains(controller.calls[len(controller.calls)-1], "|keep|") || !model.completionKept {
		t.Fatalf("keep acknowledgement: calls=%#v kept=%v", controller.calls, model.completionKept)
	}
}

func TestLiveEnterFocusesSplitTargetThroughInjectedAction(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	called := 0
	model.focusTargetCommand = func(context.Context) error {
		called++
		return nil
	}
	updated, command := model.Update(keyPress('\r', "enter"))
	model = updated
	if command == nil || called != 0 {
		t.Fatalf("focus command=%v called=%d", command, called)
	}
	model = updateLive(t, model, command())
	if called != 1 || !model.focusTarget || !strings.Contains(model.controlNotice, "focused") {
		t.Fatalf("focus result: called=%d requested=%v notice=%q", called, model.focusTarget, model.controlNotice)
	}
}

func TestLiveRenderingFitsFixedTerminalSizes(t *testing.T) {
	for _, size := range []struct{ width, height int }{{40, 18}, {56, 24}, {84, 40}, {96, 50}} {
		t.Run(fmt.Sprintf("%dx%d", size.width, size.height), func(t *testing.T) {
			model, _ := newLiveFixture(t, SurfaceSplit)
			model.applyRunUpdate(runPollMsg{Events: makeEvents(12, "phase", "state changed")})
			model = updateLive(t, model, tea.WindowSizeMsg{Width: size.width, Height: size.height})
			view := ansi.Strip(model.View())
			lines := strings.Split(strings.TrimSuffix(view, "\n"), "\n")
			if len(lines) > size.height {
				t.Fatalf("rendered %d rows into height %d\n%s", len(lines), size.height, view)
			}
			for index, line := range lines {
				if width := ansi.StringWidth(line); width > size.width {
					t.Fatalf("line %d width=%d > %d: %q", index+1, width, size.width, line)
				}
			}
			for _, text := range []string{"tmux-radar", "ARMED", "1", "5", "p", "r", "q", "?"} {
				if !strings.Contains(view, text) {
					t.Fatalf("%dx%d missing %q\n%s", size.width, size.height, text, view)
				}
			}
		})
	}
}

func TestLiveClockUpdatesWithoutRebuildingTimeline(t *testing.T) {
	model, _ := newLiveFixture(t, SurfaceSplit)
	model.applyRunUpdate(runPollMsg{Events: makeEvents(3, "phase", "same")})
	groups := model.groups
	model = updateLive(t, model, clockTickMsg(time.Unix(100, 0)))
	if &model.groups[0] != &groups[0] {
		t.Fatal("clock tick rebuilt timeline groups")
	}
}

func TestLivePollReadsCanonicalDecisionScreenAndLogsIncrementally(t *testing.T) {
	dir := t.TempDir()
	config := runmodel.DefaultConfig("%42", "persisted evidence")
	writeRunConfig(t, dir, config)
	writeJSON := func(path string, value any) {
		t.Helper()
		payload, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeJSON(filepath.Join(dir, "state.json"), runmodel.State{SchemaVersion: 1, Phase: "DECIDING", Status: "model finished"})
	if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), []byte(
		`{"schema_version":1,"kind":"model_finished","label":"model finished"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{"decisions", "screens", "backend"} {
		if err := os.Mkdir(filepath.Join(dir, directory), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writeJSON(filepath.Join(dir, "decisions", "0001.meta.json"), runmodel.DecisionMeta{
		SchemaVersion: 1, Call: 1, Model: "gpt-5.6-luna", Effort: "high", SchemaValid: true,
	})
	writeJSON(filepath.Join(dir, "decisions", "0001.json"), runmodel.Decision{
		Action: "wait", Text: "", Keys: []string{}, Safe: true, Reason: "still working",
	})
	if err := os.WriteFile(filepath.Join(dir, "screens", "0001.txt"), []byte("screen evidence\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "backend", "0001.stderr"), []byte("backend evidence\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := runmodel.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	message := pollRun(reader, dir)
	if message.Err != nil || !message.SnapshotChanged || len(message.Events) != 1 || message.Details == nil ||
		message.Details.Decision == nil || message.Details.Screen != "screen evidence\n" ||
		message.Details.Stderr != "backend evidence\n" {
		t.Fatalf("initial canonical poll=%#v", message)
	}
	unchanged := pollRun(reader, dir)
	if unchanged.Err != nil || unchanged.SnapshotChanged || len(unchanged.Events) != 0 || unchanged.Details != nil {
		t.Fatalf("unchanged poll reparsed derived evidence=%#v", unchanged)
	}
}

func TestLiveReaderErrorsAreRateLimited(t *testing.T) {
	dir := t.TempDir()
	config := runmodel.DefaultConfig("%42", "rate limit reader errors")
	writeRunConfig(t, dir, config)
	reader, err := runmodel.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if initial := pollRun(reader, dir); initial.Err != nil || !initial.SnapshotChanged {
		t.Fatalf("initial poll=%#v", initial)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte("{bad json}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := time.Now()
	message := waitForRunChange(ctx, reader, dir)()
	if elapsed := time.Since(started); elapsed < 200*time.Millisecond {
		t.Fatalf("reader error retried without 250ms pacing: %v", elapsed)
	}
	if result, ok := message.(runPollMsg); !ok || result.Err == nil {
		t.Fatalf("paced reader error=%#v", message)
	}
}
