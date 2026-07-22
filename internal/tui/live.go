package tui

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/enginebridge"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

const (
	runPollInterval       = 250 * time.Millisecond
	maxDetailBytes        = 1 << 20
	maxListedRunArtifacts = 512
	artifactOmittedLabel  = "... additional artifacts omitted"
)

type Surface string

const (
	SurfaceSplit Surface = "split"
	SurfacePopup Surface = "popup"
)

type LiveView int

const (
	ViewTimeline LiveView = iota
	ViewDecision
	ViewScreen
	ViewConfig
	ViewLogs
	liveViewCount
)

type ControlClient interface {
	Control(context.Context, string, string, string, string) (enginebridge.ControlResult, error)
}

type LiveOptions struct {
	RunDir      string
	RunID       string
	Reader      *runmodel.Reader
	Controller  ControlClient
	Surface     Surface
	ReadOnly    bool
	RequestID   func() string
	FocusTarget func(context.Context) error
}

type TimelineGroup struct {
	Signature string
	Events    []runmodel.Event
	Count     int
	Expanded  bool
}

type pendingControl struct {
	Action    string
	RequestID string
	StartedAt time.Time
}

type controlResultMsg struct {
	Action    string
	RequestID string
	Result    enginebridge.ControlResult
	Err       error
}

type runPollMsg struct {
	Snapshot        runmodel.Snapshot
	SnapshotChanged bool
	Events          []runmodel.Event
	Details         *runDetails
	Err             error
}

type pollStoppedMsg struct{}
type clockTickMsg time.Time
type completionCloseMsg struct{ TimerID uint64 }
type focusTargetResultMsg struct{ Err error }

type artifactInfo struct {
	Path string
	Size int64
}

type runDetails struct {
	Decision     *runmodel.Decision
	DecisionMeta *runmodel.DecisionMeta
	DecisionRaw  string
	DecisionPath string
	Screen       string
	ScreenPath   string
	Stderr       string
	StderrPath   string
	Files        []artifactInfo
}

type LiveModel struct {
	runDir             string
	runID              string
	reader             *runmodel.Reader
	controller         ControlClient
	surface            Surface
	readOnly           bool
	requestID          func() string
	focusTargetCommand func(context.Context) error

	pollContext context.Context
	pollCancel  context.CancelFunc

	snapshot runmodel.Snapshot
	events   []runmodel.Event
	groups   []TimelineGroup
	details  runDetails

	activeView     LiveView
	selectedGroup  int
	viewport       viewport.Model
	viewOffsets    [liveViewCount]int
	timelineFollow bool
	newEvents      int
	width          int
	height         int
	now            time.Time

	pending            *pendingControl
	controlNotice      string
	controlError       string
	confirmStop        bool
	showHelp           bool
	focusTarget        bool
	detached           bool
	closed             bool
	completionTimerID  uint64
	completionKept     bool
	completionDeadline time.Time
}

func NewLive(options LiveOptions) (LiveModel, error) {
	if options.RunDir == "" || options.RunID == "" {
		return LiveModel{}, errors.New("live console requires a run directory and run ID")
	}
	reader := options.Reader
	if reader == nil {
		var err error
		reader, err = runmodel.Open(options.RunDir)
		if err != nil {
			return LiveModel{}, err
		}
	}
	if options.Surface == "" {
		options.Surface = SurfaceSplit
	}
	requestID := options.RequestID
	if requestID == nil {
		requestID = randomRequestID
	}
	pollContext, pollCancel := context.WithCancel(context.Background())
	view := viewport.New(viewport.WithWidth(72), viewport.WithHeight(16))
	view.SoftWrap = true
	view.FillHeight = true
	view.MouseWheelEnabled = true
	model := LiveModel{
		runDir: options.RunDir, runID: options.RunID, reader: reader,
		controller: options.Controller, surface: options.Surface, readOnly: options.ReadOnly,
		requestID: requestID, focusTargetCommand: options.FocusTarget,
		pollContext: pollContext, pollCancel: pollCancel,
		viewport: view, timelineFollow: true, width: 72, height: 24, now: time.Now(),
	}
	model.refreshViewport()
	return model, nil
}

func (model LiveModel) Init() tea.Cmd {
	return tea.Batch(waitForRunChange(model.pollContext, model.reader, model.runDir), nextClockTick())
}

func (model LiveModel) Update(message tea.Msg) (LiveModel, tea.Cmd) {
	switch message := message.(type) {
	case tea.WindowSizeMsg:
		model.resize(message.Width, message.Height)
		return model, nil
	case runPollMsg:
		if message.Err != nil {
			model.controlError = "Run reader: " + message.Err.Error()
			return model, waitForRunChange(model.pollContext, model.reader, model.runDir)
		}
		model.applyRunUpdate(message)
		if model.snapshot.Final != nil {
			model.pollCancel()
			return model, model.scheduleCompletionClose()
		}
		return model, waitForRunChange(model.pollContext, model.reader, model.runDir)
	case pollStoppedMsg:
		return model, nil
	case clockTickMsg:
		model.now = time.Time(message)
		if model.closed {
			return model, nil
		}
		return model, nextClockTick()
	case controlResultMsg:
		return model.applyControlResult(message)
	case completionCloseMsg:
		if message.TimerID != model.completionTimerID || model.completionKept || model.closed {
			return model, nil
		}
		model.close()
		return model, tea.Quit
	case focusTargetResultMsg:
		if message.Err != nil {
			model.controlError = "Focus target: " + message.Err.Error()
			model.controlNotice = ""
		} else {
			model.focusTarget = true
			model.controlError = ""
			model.controlNotice = "Target pane focused"
		}
		return model, nil
	case tea.KeyPressMsg:
		return model.handleKey(message)
	case tea.MouseWheelMsg:
		before := model.viewport.YOffset()
		updated, command := model.viewport.Update(message)
		model.viewport = updated
		if model.activeView == ViewTimeline && model.viewport.YOffset() < before {
			model.timelineFollow = false
		}
		model.viewOffsets[model.activeView] = model.viewport.YOffset()
		return model, command
	}
	return model, nil
}

func (model *LiveModel) applyRunUpdate(message runPollMsg) {
	pinnedOffset := model.viewport.YOffset()
	wasPinned := model.activeView == ViewTimeline && !model.timelineFollow
	if message.SnapshotChanged {
		model.snapshot = message.Snapshot
	}
	if message.Details != nil {
		model.details = *message.Details
	}
	if len(message.Events) > 0 {
		model.events = append(model.events, message.Events...)
		model.rebuildGroups()
		if model.timelineFollow {
			model.selectedGroup = max(0, len(model.groups)-1)
		} else {
			model.newEvents += len(message.Events)
		}
	}
	model.refreshViewport()
	if wasPinned {
		model.viewport.SetYOffset(pinnedOffset)
		model.viewOffsets[ViewTimeline] = model.viewport.YOffset()
	} else if model.activeView == ViewTimeline && model.timelineFollow {
		model.viewport.GotoBottom()
		model.viewOffsets[ViewTimeline] = model.viewport.YOffset()
	}
}

func (model *LiveModel) rebuildGroups() {
	previous := model.groups
	groups := make([]TimelineGroup, 0, len(model.events))
	for _, event := range model.events {
		signature := eventSignature(event)
		if len(groups) > 0 && groups[len(groups)-1].Signature == signature {
			group := &groups[len(groups)-1]
			group.Events = append(group.Events, event)
			group.Count = len(group.Events)
			continue
		}
		expanded := false
		if len(groups) < len(previous) && previous[len(groups)].Signature == signature {
			expanded = previous[len(groups)].Expanded
		}
		groups = append(groups, TimelineGroup{Signature: signature, Events: []runmodel.Event{event}, Count: 1, Expanded: expanded})
	}
	model.groups = groups
	if len(groups) == 0 {
		model.selectedGroup = 0
	} else if model.selectedGroup >= len(groups) {
		model.selectedGroup = len(groups) - 1
	}
}

func eventSignature(event runmodel.Event) string {
	errorKey := ""
	if event.Error != nil {
		errorKey = event.Error.Class + "|" + event.Error.Code + "|" + event.Error.Summary
	}
	return strings.Join([]string{event.Kind, event.Source, event.Label, event.Record, event.Phase, event.Status, errorKey}, "\x00")
}

func (model LiveModel) handleKey(message tea.KeyPressMsg) (LiveModel, tea.Cmd) {
	key := message.String()
	if key == "ctrl+c" {
		model.close()
		return model, tea.Quit
	}
	if model.showHelp {
		switch key {
		case "?", "esc", "q":
			model.showHelp = false
			model.refreshViewport()
		}
		return model, nil
	}
	if model.confirmStop {
		switch key {
		case "y", "enter":
			model.confirmStop = false
			return model.startControl("stop")
		case "n", "esc", "q":
			model.confirmStop = false
			model.controlNotice = "Stop cancelled"
		}
		return model, nil
	}
	if len(key) == 1 && key[0] >= '1' && key[0] <= '5' {
		model.setActiveView(LiveView(key[0] - '1'))
		return model, nil
	}
	if model.snapshot.Final != nil && (key == "p" || key == "r") {
		model.controlNotice = "Run is finished; start a new supervision run to continue"
		model.controlError = ""
		return model, nil
	}
	switch key {
	case "?":
		model.showHelp = true
		model.refreshViewport()
	case "c":
		model.setActiveView(ViewConfig)
	case "g":
		model.viewport.SetYOffset(0)
		if model.activeView == ViewTimeline {
			model.timelineFollow = false
			model.selectedGroup = 0
		}
	case "G":
		model.viewport.GotoBottom()
		if model.activeView == ViewTimeline {
			model.timelineFollow = true
			model.newEvents = 0
			model.selectedGroup = max(0, len(model.groups)-1)
		}
	case "e":
		if model.activeView == ViewTimeline && len(model.groups) > 0 {
			model.groups[model.selectedGroup].Expanded = !model.groups[model.selectedGroup].Expanded
			model.refreshViewport()
		}
	case "j", "down":
		model.scroll(1)
	case "k", "up":
		model.scroll(-1)
	case "K":
		if model.snapshot.Final == nil {
			model.controlNotice = "Keep is available only after completion"
			return model, nil
		}
		updated, command := model.startControl("keep")
		if command != nil {
			updated.completionKept = true
			updated.completionTimerID++
			updated.completionDeadline = time.Time{}
		}
		return updated, command
	case "pgdown":
		model.viewport.PageDown()
	case "pgup":
		model.viewport.PageUp()
		if model.activeView == ViewTimeline {
			model.timelineFollow = false
		}
	case "p":
		if model.isPaused() {
			return model.startControl("resume")
		}
		return model.startControl("pause")
	case "r":
		return model.startControl("reassess")
	case "enter":
		if model.surface == SurfacePopup && model.snapshot.Final == nil {
			return model.startControl("detach")
		}
		if model.focusTargetCommand == nil {
			model.controlError = "Target focus action is unavailable"
			return model, nil
		}
		model.controlNotice = "Target focus pending"
		model.controlError = ""
		focusTarget := model.focusTargetCommand
		return model, func() tea.Msg {
			return focusTargetResultMsg{Err: focusTarget(context.Background())}
		}
	case "q":
		if model.snapshot.Final != nil {
			model.close()
			return model, tea.Quit
		}
		model.confirmStop = true
		model.controlNotice = "Stop supervision? y confirm · n cancel"
	}
	return model, nil
}

func (model *LiveModel) scroll(delta int) {
	if model.activeView == ViewTimeline && len(model.groups) > 0 {
		model.selectedGroup = max(0, min(len(model.groups)-1, model.selectedGroup+delta))
	}
	if delta > 0 {
		model.viewport.ScrollDown(delta)
	} else {
		model.viewport.ScrollUp(-delta)
		if model.activeView == ViewTimeline {
			model.timelineFollow = false
		}
	}
	model.viewOffsets[model.activeView] = model.viewport.YOffset()
}

func (model LiveModel) startControl(action string) (LiveModel, tea.Cmd) {
	if model.readOnly {
		model.controlError = "Attached viewer is read-only"
		return model, nil
	}
	if model.controller == nil {
		model.controlError = "Control bridge is unavailable"
		return model, nil
	}
	if model.pending != nil {
		model.controlError = "A control request is already pending"
		return model, nil
	}
	if model.snapshot.Config.Pane == "" {
		model.controlError = "Run identity is still loading"
		return model, nil
	}
	if action == "keep" && model.snapshot.Final == nil {
		model.controlError = "Keep is available only after completion"
		return model, nil
	}
	requestID := model.requestID()
	model.pending = &pendingControl{Action: action, RequestID: requestID, StartedAt: time.Now()}
	model.controlNotice = action + " pending"
	model.controlError = ""
	controller := model.controller
	runID := model.runID
	pane := model.snapshot.Config.Pane
	return model, func() tea.Msg {
		result, err := controller.Control(context.Background(), runID, pane, action, requestID)
		return controlResultMsg{Action: action, RequestID: requestID, Result: result, Err: err}
	}
}

func (model LiveModel) applyControlResult(message controlResultMsg) (LiveModel, tea.Cmd) {
	if model.pending == nil || model.pending.RequestID != message.RequestID || model.pending.Action != message.Action {
		return model, nil
	}
	model.pending = nil
	if message.Err != nil {
		model.controlError = message.Err.Error()
		model.controlNotice = ""
		return model.afterControlFailure(message.Action)
	}
	if message.Result.RunID != model.runID || message.Result.Pane != model.snapshot.Config.Pane ||
		message.Result.Action != message.Action || message.Result.RequestID != message.RequestID {
		model.controlError = "Control acknowledgement identity does not match the pending request"
		model.controlNotice = ""
		return model.afterControlFailure(message.Action)
	}
	if !message.Result.OK || message.Result.Status != "acknowledged" {
		if message.Result.Error != nil {
			model.controlError = firstNonEmpty(message.Result.Error.Summary, message.Result.Error.Detail, message.Result.Status)
		} else {
			model.controlError = firstNonEmpty(message.Result.Status, "control was not acknowledged")
		}
		model.controlNotice = ""
		return model.afterControlFailure(message.Action)
	}
	model.controlError = ""
	model.controlNotice = message.Action + " acknowledged"
	if message.Action == "detach" {
		model.detached = true
		model.close()
		return model, tea.Quit
	}
	if message.Action == "keep" {
		model.completionKept = true
		model.completionDeadline = time.Time{}
	}
	return model, nil
}

func (model LiveModel) afterControlFailure(action string) (LiveModel, tea.Cmd) {
	if action != "keep" {
		return model, nil
	}
	model.completionKept = false
	return model, model.scheduleCompletionCloseAfter(time.Second)
}

func (model *LiveModel) scheduleCompletionClose() tea.Cmd {
	delay := model.snapshot.Config.Values.CompletionCloseDelay.Value
	if delay < 0 {
		delay = 0
	}
	return model.scheduleCompletionCloseAfter(time.Duration(delay) * time.Second)
}

func (model *LiveModel) scheduleCompletionCloseAfter(delay time.Duration) tea.Cmd {
	if model.completionKept || model.closed {
		return nil
	}
	model.completionTimerID++
	timerID := model.completionTimerID
	model.completionDeadline = time.Now().Add(delay)
	return tea.Tick(delay, func(time.Time) tea.Msg { return completionCloseMsg{TimerID: timerID} })
}

func (model *LiveModel) setActiveView(view LiveView) {
	if view < 0 || view >= liveViewCount {
		return
	}
	model.viewOffsets[model.activeView] = model.viewport.YOffset()
	model.activeView = view
	model.refreshViewport()
	if view == ViewTimeline && model.timelineFollow {
		model.viewport.GotoBottom()
	} else {
		model.viewport.SetYOffset(model.viewOffsets[view])
	}
}

func (model *LiveModel) resize(width, height int) {
	if width > 0 {
		model.width = width
	}
	if height > 0 {
		model.height = height
	}
	model.viewport.SetWidth(max(20, model.width))
	model.viewport.SetHeight(max(1, model.height-liveChromeRows(model.width)))
	model.refreshViewport()
}

func (model LiveModel) isPaused() bool {
	return model.snapshot.State != nil && model.snapshot.State.Phase == "PAUSED_USER"
}

func (model *LiveModel) close() {
	if model.closed {
		return
	}
	model.closed = true
	model.pollCancel()
}

func waitForRunChange(ctx context.Context, reader *runmodel.Reader, runDir string) tea.Cmd {
	return func() tea.Msg {
		ticker := time.NewTicker(runPollInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return pollStoppedMsg{}
			case <-ticker.C:
			}
			message := pollRun(reader, runDir)
			if message.Err != nil || message.SnapshotChanged || len(message.Events) > 0 {
				return message
			}
		}
	}
}

func pollRun(reader *runmodel.Reader, runDir string) runPollMsg {
	snapshot, changed, err := reader.Snapshot()
	if err != nil {
		return runPollMsg{Err: err}
	}
	events, err := reader.PollEvents()
	if err != nil {
		return runPollMsg{Err: err}
	}
	message := runPollMsg{Snapshot: snapshot, SnapshotChanged: changed, Events: events}
	if changed || len(events) > 0 {
		details, err := loadRunDetails(runDir)
		if err != nil {
			message.Err = err
		} else {
			message.Details = &details
		}
	}
	return message
}

func nextClockTick() tea.Cmd {
	return tea.Tick(time.Second, func(now time.Time) tea.Msg { return clockTickMsg(now) })
}

func randomRequestID() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return fmt.Sprintf("request-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(value)
}

func loadRunDetails(runDir string) (runDetails, error) {
	details := runDetails{}
	stem, err := latestStem(filepath.Join(runDir, "decisions"), ".meta.json")
	if err != nil {
		return runDetails{}, err
	}
	if stem != "" {
		metaPath := filepath.Join(runDir, "decisions", stem+".meta.json")
		if err := decodeFile(metaPath, &details.DecisionMeta); err != nil {
			return runDetails{}, err
		}
		decisionPath := filepath.Join(runDir, "decisions", stem+".json")
		payload, err := readBoundedFile(decisionPath)
		if err != nil {
			return runDetails{}, err
		}
		details.DecisionPath = decisionPath
		details.DecisionRaw = string(payload)
		var decision runmodel.Decision
		if json.Unmarshal(payload, &decision) == nil && decision.Validate() == nil {
			details.Decision = &decision
		}
	}
	screenStem, err := latestStem(filepath.Join(runDir, "screens"), ".txt")
	if err != nil {
		return runDetails{}, err
	}
	if screenStem != "" {
		details.ScreenPath = filepath.Join(runDir, "screens", screenStem+".txt")
		payload, err := readBoundedFile(details.ScreenPath)
		if err != nil {
			return runDetails{}, err
		}
		details.Screen = string(payload)
	}
	stderrStem, err := latestStem(filepath.Join(runDir, "backend"), ".stderr")
	if err != nil {
		return runDetails{}, err
	}
	if stderrStem != "" {
		details.StderrPath = filepath.Join(runDir, "backend", stderrStem+".stderr")
		payload, err := readBoundedFile(details.StderrPath)
		if err != nil {
			return runDetails{}, err
		}
		details.Stderr = string(payload)
	}
	files, err := listRunArtifacts(runDir)
	if err != nil {
		return runDetails{}, err
	}
	details.Files = files
	return details, nil
}

func latestStem(directory, suffix string) (string, error) {
	entries, err := os.ReadDir(directory)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("read %s: %w", filepath.Base(directory), err)
	}
	var stems []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), suffix) {
			stems = append(stems, strings.TrimSuffix(entry.Name(), suffix))
		}
	}
	sort.Strings(stems)
	if len(stems) == 0 {
		return "", nil
	}
	return stems[len(stems)-1], nil
}

func decodeFile[T any](path string, target **T) error {
	payload, err := readBoundedFile(path)
	if err != nil {
		return err
	}
	var value T
	if err := json.Unmarshal(payload, &value); err != nil {
		return fmt.Errorf("decode %s: %w", filepath.Base(path), err)
	}
	*target = &value
	return nil
}

func readBoundedFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	payload, err := io.ReadAll(io.LimitReader(file, maxDetailBytes+1))
	if err != nil {
		return nil, err
	}
	if len(payload) > maxDetailBytes {
		return nil, fmt.Errorf("%s exceeds %d bytes", filepath.Base(path), maxDetailBytes)
	}
	return payload, nil
}

func listRunArtifacts(runDir string) ([]artifactInfo, error) {
	artifacts := make([]artifactInfo, 0, 32)
	truncated := false
	err := filepath.WalkDir(runDir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if len(artifacts) == maxListedRunArtifacts {
			truncated = true
			return fs.SkipAll
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(runDir, path)
		if err != nil {
			return err
		}
		artifacts = append(artifacts, artifactInfo{Path: relative, Size: info.Size()})
		return nil
	})
	sort.Slice(artifacts, func(left, right int) bool { return artifacts[left].Path < artifacts[right].Path })
	if truncated {
		artifacts = append(artifacts, artifactInfo{Path: artifactOmittedLabel})
	}
	return artifacts, err
}
