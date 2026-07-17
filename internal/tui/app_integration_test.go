package tui

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/enginebridge"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

type fakeSupervisorEngine struct {
	startResult      runmodel.StartResult
	startErr         error
	startRequests    []enginebridge.StartRequest
	heartbeatAtStart bool
	startEntered     chan struct{}
	waitForCancel    bool
	controls         []string
	controlErr       error
}

func (engine *fakeSupervisorEngine) Start(ctx context.Context, request enginebridge.StartRequest) (runmodel.StartResult, error) {
	engine.startRequests = append(engine.startRequests, request)
	if request.Owner != nil {
		_, err := os.Stat(request.Owner.HeartbeatPath)
		engine.heartbeatAtStart = err == nil
	}
	if engine.startEntered != nil {
		close(engine.startEntered)
	}
	if engine.waitForCancel {
		<-ctx.Done()
		return runmodel.StartResult{}, ctx.Err()
	}
	return engine.startResult, engine.startErr
}

func (engine *fakeSupervisorEngine) Control(_ context.Context, runID, pane, action, requestID string) (enginebridge.ControlResult, error) {
	engine.controls = append(engine.controls, strings.Join([]string{runID, pane, action, requestID}, "|"))
	return enginebridge.ControlResult{
		ProtocolVersion: runmodel.CurrentProtocolVersion,
		SchemaVersion:   runmodel.CurrentSchemaVersion,
		OK:              engine.controlErr == nil,
		Status:          "acknowledged",
		RunID:           runID,
		Pane:            pane,
		Action:          action,
		RequestID:       requestID,
	}, engine.controlErr
}

func newAppRun(t *testing.T, stateRoot, runID string) string {
	t.Helper()
	runDir := filepath.Join(stateRoot, "ai-runs", runID)
	if err := os.MkdirAll(runDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeRunConfig(t, runDir, runmodel.DefaultConfig("%42", "finish the current task"))
	return runDir
}

func readyApp(t *testing.T, engine SupervisorEngine) *App {
	t.Helper()
	result := compatiblePreflight()
	root := t.TempDir()
	return NewApp(AppOptions{
		Setup:  SetupOptions{TargetPane: "%42", Entry: EntryQuick, Preflight: &result},
		Engine: engine, StateRoot: root, MonitorPane: "%99", Surface: SurfaceSplit,
	})
}

func requestAppStart(t *testing.T, app *App) tea.Cmd {
	t.Helper()
	app.setup.requestLaunch()
	_, command := app.Update(struct{}{})
	if command == nil || app.phase != phaseStarting || app.lifecycle.lease == nil {
		t.Fatalf("start not scheduled: phase=%v command=%v lease=%v", app.phase, command, app.lifecycle.lease)
	}
	return command
}

func TestAppCreatesLeaseBeforeEngineStartAndKeepsItThroughLive(t *testing.T) {
	engine := &fakeSupervisorEngine{}
	app := readyApp(t, engine)
	runDir := newAppRun(t, app.stateRoot, "run-1")
	engine.startResult = runmodel.StartResult{
		ProtocolVersion: 1, OK: true, Status: "started", RunID: "run-1", RunDir: runDir, WatcherPID: 1234,
	}
	command := requestAppStart(t, app)
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	if _, err := os.Stat(heartbeatPath); err != nil {
		t.Fatalf("heartbeat missing before engine command: %v", err)
	}
	_, _ = app.Update(command())
	if app.phase != phaseLive || app.live.readOnly || !engine.heartbeatAtStart {
		t.Fatalf("live transition: phase=%v readOnly=%v heartbeatAtStart=%v", app.phase, app.live.readOnly, engine.heartbeatAtStart)
	}
	if len(engine.startRequests) != 1 || engine.startRequests[0].Config.Goal != runmodel.DefaultGoal {
		t.Fatalf("start requests = %#v", engine.startRequests)
	}
	if _, err := os.Stat(heartbeatPath); err != nil {
		t.Fatalf("heartbeat not retained by live owner: %v", err)
	}
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("heartbeat after app close: %v", err)
	}
}

func TestAppStartFailureReturnsToSetupAndClosesLease(t *testing.T) {
	engine := &fakeSupervisorEngine{startErr: errors.New("engine unavailable")}
	app := readyApp(t, engine)
	command := requestAppStart(t, app)
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	_, _ = app.Update(command())
	if app.phase != phaseSetup || !strings.Contains(app.setup.blockingError, "engine unavailable") {
		t.Fatalf("phase=%v blockingError=%q", app.phase, app.setup.blockingError)
	}
	if app.lifecycle.lease != nil {
		t.Fatal("failed start retained owner lease")
	}
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("failed start heartbeat: %v", err)
	}
}

func TestAppCloseCancelsInFlightStartAndRemovesHeartbeat(t *testing.T) {
	engine := &fakeSupervisorEngine{startEntered: make(chan struct{}), waitForCancel: true}
	app := readyApp(t, engine)
	command := requestAppStart(t, app)
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	message := make(chan tea.Msg, 1)
	go func() { message <- command() }()
	<-engine.startEntered
	if err := app.Close(); err != nil {
		t.Fatal(err)
	}
	result := <-message
	if startMessage, ok := result.(startRunResultMsg); !ok || !errors.Is(startMessage.err, context.Canceled) {
		t.Fatalf("cancelled start message = %#v", result)
	}
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("cancelled start heartbeat: %v", err)
	}
}

func TestAppAlreadyActiveAttachesReadOnlyWithoutStealingOwner(t *testing.T) {
	engine := &fakeSupervisorEngine{}
	app := readyApp(t, engine)
	runDir := newAppRun(t, app.stateRoot, "run-existing")
	engine.startResult = runmodel.StartResult{
		ProtocolVersion: 1, OK: true, Status: "already-active", RunID: "run-existing", RunDir: runDir, WatcherPID: 4321,
	}
	command := requestAppStart(t, app)
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	message := command()
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("viewer candidate lease was not closed before attach: %v", err)
	}
	_, _ = app.Update(message)
	if app.phase != phaseLive || !app.live.readOnly || app.lifecycle.lease != nil {
		t.Fatalf("existing attach: phase=%v readOnly=%v lease=%v", app.phase, app.live.readOnly, app.lifecycle.lease)
	}
}

func TestAppReaderFailureStopsNewRunAndClosesLease(t *testing.T) {
	engine := &fakeSupervisorEngine{}
	app := readyApp(t, engine)
	missingRunDir := filepath.Join(app.stateRoot, "ai-runs", "missing")
	engine.startResult = runmodel.StartResult{
		ProtocolVersion: 1, OK: true, Status: "started", RunID: "run-bad", RunDir: missingRunDir, WatcherPID: 777,
	}
	command := requestAppStart(t, app)
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	_, _ = app.Update(command())
	if app.phase != phaseSetup || app.lifecycle.lease != nil || len(engine.controls) != 1 {
		t.Fatalf("reader cleanup: phase=%v lease=%v controls=%#v", app.phase, app.lifecycle.lease, engine.controls)
	}
	if !strings.Contains(engine.controls[0], "run-bad|%42|stop|") {
		t.Fatalf("cleanup control = %q", engine.controls[0])
	}
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("reader failure heartbeat: %v", err)
	}
}

func TestAppLiveCloseAndPopupDetachReleaseLease(t *testing.T) {
	engine := &fakeSupervisorEngine{}
	app := readyApp(t, engine)
	runDir := newAppRun(t, app.stateRoot, "run-popup")
	app.surface = SurfacePopup
	app.monitorPane = ""
	engine.startResult = runmodel.StartResult{
		ProtocolVersion: 1, OK: true, Status: "started", RunID: "run-popup", RunDir: runDir, WatcherPID: 888,
	}
	command := requestAppStart(t, app)
	_, _ = app.Update(command())
	heartbeatPath := app.lifecycle.lease.Descriptor().HeartbeatPath
	app.live.snapshot.Config = runmodel.DefaultConfig("%42", "goal")
	app.live.detached = true
	app.live.closed = true
	_, _ = app.Update(struct{}{})
	if app.lifecycle.lease != nil {
		t.Fatal("detached popup retained owner lease")
	}
	if _, err := os.Stat(heartbeatPath); !os.IsNotExist(err) {
		t.Fatalf("detached popup heartbeat: %v", err)
	}
}

func TestAppViewDeclaresModernTerminalModes(t *testing.T) {
	app := readyApp(t, &fakeSupervisorEngine{})
	view := app.View()
	if !view.AltScreen || view.MouseMode != tea.MouseModeCellMotion {
		t.Fatalf("terminal modes: alt=%v mouse=%v", view.AltScreen, view.MouseMode)
	}
}
