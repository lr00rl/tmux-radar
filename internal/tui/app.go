package tui

import (
	"context"
	"errors"
	"fmt"
	"sync"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/enginebridge"
	"github.com/lr00rl/tmux-radar/internal/preflight"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

type SupervisorEngine interface {
	Start(context.Context, enginebridge.StartRequest) (runmodel.StartResult, error)
	Control(context.Context, string, string, string, string) (enginebridge.ControlResult, error)
}

type AppOptions struct {
	Setup       SetupOptions
	Checker     *preflight.Checker
	Engine      SupervisorEngine
	StateRoot   string
	MonitorPane string
	Surface     Surface
	FocusTarget func(context.Context) error
}

type appPhase uint8

const (
	phaseSetup appPhase = iota
	phaseStarting
	phaseLive
)

type appLifecycle struct {
	lease *OwnerLease
}

type startRunResultMsg struct {
	requestID uint64
	result    runmodel.StartResult
	reader    *runmodel.Reader
	readOnly  bool
	err       error
}

type App struct {
	setup       SetupModel
	live        LiveModel
	checker     *preflight.Checker
	engine      SupervisorEngine
	stateRoot   string
	monitorPane string
	surface     Surface
	focusTarget func(context.Context) error
	phase       appPhase
	lifecycle   *appLifecycle

	context         context.Context
	cancel          context.CancelFunc
	startRequestID  uint64
	closeOnce       sync.Once
	closeErr        error
	startupError    error
	startupComplete bool
}

func NewApp(options AppOptions) *App {
	if options.Surface == "" {
		options.Surface = SurfaceSplit
	}
	appContext, cancel := context.WithCancel(context.Background())
	app := &App{
		setup: NewSetup(options.Setup), checker: options.Checker, engine: options.Engine,
		stateRoot: options.StateRoot, monitorPane: options.MonitorPane, surface: options.Surface,
		focusTarget: options.FocusTarget,
		phase:       phaseSetup, lifecycle: &appLifecycle{}, context: appContext, cancel: cancel,
	}
	if app.checker != nil {
		app.setup.beginPreflight()
	}
	return app
}

func NewLiveApp(options LiveOptions) (*App, error) {
	live, err := NewLive(options)
	if err != nil {
		return nil, err
	}
	appContext, cancel := context.WithCancel(context.Background())
	return &App{
		live: live, surface: live.surface, phase: phaseLive,
		lifecycle: &appLifecycle{}, context: appContext, cancel: cancel, startupComplete: true,
	}, nil
}

func (app *App) Init() tea.Cmd {
	switch app.phase {
	case phaseLive:
		return app.live.Init()
	case phaseSetup:
		if app.checker != nil {
			config, err := app.setup.reviewedConfig()
			return runPreflight(app.context, *app.checker, config, err, app.setup.preflightRequestID)
		}
	}
	return nil
}

func runPreflight(
	ctx context.Context, checker preflight.Checker, config runmodel.Config, configErr error, requestID uint64,
) tea.Cmd {
	return func() tea.Msg {
		if configErr != nil {
			return PreflightResultMsg{RequestID: requestID, Err: configErr}
		}
		result, err := checker.CheckConfig(ctx, config)
		return PreflightResultMsg{RequestID: requestID, Result: result, Err: err}
	}
}

func (app *App) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch app.phase {
	case phaseSetup:
		return app.updateSetup(message)
	case phaseStarting:
		return app.updateStarting(message)
	case phaseLive:
		return app.updateLive(message)
	default:
		return app, nil
	}
}

func (app *App) updateSetup(message tea.Msg) (tea.Model, tea.Cmd) {
	previousRequestID := app.setup.preflightRequestID
	updated, command := app.setup.Update(message)
	app.setup = updated
	if app.checker != nil && app.setup.preflightRequestID != previousRequestID {
		config, err := app.setup.reviewedConfig()
		command = combineCommands(
			command,
			runPreflight(app.context, *app.checker, config, err, app.setup.preflightRequestID),
		)
	}
	if !app.setup.launchRequested {
		return app, command
	}
	app.setup.launchRequested = false
	config, err := app.setup.immutableConfig()
	if err != nil {
		app.setup.blockingError = err.Error()
		return app, command
	}
	if app.engine == nil {
		app.setup.blockingError = "Start failed: supervisor engine is unavailable"
		return app, command
	}
	lease, err := StartOwnerLease(app.stateRoot, app.surface, app.monitorPane)
	if err != nil {
		app.setup.blockingError = "Start failed: " + err.Error()
		return app, command
	}
	app.lifecycle.lease = lease
	app.startRequestID++
	requestID := app.startRequestID
	app.phase = phaseStarting
	app.setup.blockingError = "Starting supervisor run..."
	request := enginebridge.StartRequest{
		ProtocolVersion: runmodel.CurrentProtocolVersion, ConfigSchemaVersion: runmodel.CurrentSchemaVersion,
		StateRoot: app.stateRoot, TargetPane: config.Pane, Config: config,
	}
	descriptor := lease.Descriptor()
	request.Owner = &descriptor
	startCommand := startRun(app.context, app.engine, requestID, request, lease)
	return app, combineCommands(command, startCommand)
}

func (app *App) updateStarting(message tea.Msg) (tea.Model, tea.Cmd) {
	switch message := message.(type) {
	case tea.WindowSizeMsg:
		app.setup.resize(message.Width, message.Height)
		return app, nil
	case tea.KeyPressMsg:
		if message.String() == "ctrl+c" || message.String() == "q" {
			_ = app.Close()
			return app, tea.Quit
		}
		return app, nil
	case startRunResultMsg:
		if message.requestID != app.startRequestID {
			return app, nil
		}
		if message.err != nil {
			_ = app.closeLease()
			app.phase = phaseSetup
			app.startupError = message.err
			app.setup.blockingError = "Start failed: " + message.err.Error()
			return app, nil
		}
		if message.readOnly {
			_ = app.closeLease()
		}
		live, err := NewLive(LiveOptions{
			RunDir: message.result.RunDir, RunID: message.result.RunID, Reader: message.reader,
			Controller: app.engine, Surface: app.surface, ReadOnly: message.readOnly,
			FocusTarget: app.focusTarget,
		})
		if err != nil {
			_ = app.closeLease()
			app.phase = phaseSetup
			app.startupError = err
			app.setup.blockingError = "Start failed: " + err.Error()
			return app, nil
		}
		live.resize(app.setup.width, app.setup.height)
		app.live = live
		app.phase = phaseLive
		app.startupError = nil
		app.startupComplete = true
		return app, app.live.Init()
	}
	return app, nil
}

func startRun(
	ctx context.Context,
	engine SupervisorEngine,
	requestID uint64,
	request enginebridge.StartRequest,
	lease *OwnerLease,
) tea.Cmd {
	return func() tea.Msg {
		result, err := engine.Start(ctx, request)
		if err != nil {
			_ = lease.Close()
			return startRunResultMsg{requestID: requestID, err: err}
		}
		if !result.OK {
			_ = lease.Close()
			return startRunResultMsg{requestID: requestID, err: startResultError(result)}
		}

		readOnly := result.Status == "already-active"
		if readOnly {
			_ = lease.Close()
		}
		reader, openErr := runmodel.Open(result.RunDir)
		if openErr == nil {
			return startRunResultMsg{requestID: requestID, result: result, reader: reader, readOnly: readOnly}
		}

		cleanupErr := error(nil)
		if !readOnly {
			_, cleanupErr = engine.Control(ctx, result.RunID, request.TargetPane, "stop", randomRequestID())
		}
		_ = lease.Close()
		if cleanupErr != nil {
			openErr = errors.Join(openErr, fmt.Errorf("stop unreadable run: %w", cleanupErr))
		}
		return startRunResultMsg{requestID: requestID, err: fmt.Errorf("open started run: %w", openErr)}
	}
}

func startResultError(result runmodel.StartResult) error {
	if result.Error != nil {
		return errors.New(firstNonEmpty(result.Error.Summary, result.Error.Detail, result.Code, result.Status))
	}
	return errors.New(firstNonEmpty(result.Code, result.Status, "engine rejected start request"))
}

func (app *App) updateLive(message tea.Msg) (tea.Model, tea.Cmd) {
	updated, command := app.live.Update(message)
	app.live = updated
	if app.live.closed {
		_ = app.closeLease()
	}
	return app, command
}

func combineCommands(commands ...tea.Cmd) tea.Cmd {
	filtered := make([]tea.Cmd, 0, len(commands))
	for _, command := range commands {
		if command != nil {
			filtered = append(filtered, command)
		}
	}
	switch len(filtered) {
	case 0:
		return nil
	case 1:
		return filtered[0]
	default:
		return tea.Batch(filtered...)
	}
}

func (app *App) closeLease() error {
	if app.lifecycle == nil || app.lifecycle.lease == nil {
		return nil
	}
	lease := app.lifecycle.lease
	app.lifecycle.lease = nil
	return lease.Close()
}

func (app *App) Close() error {
	if app == nil {
		return nil
	}
	app.closeOnce.Do(func() {
		app.cancel()
		if app.phase == phaseLive {
			app.live.close()
		}
		app.closeErr = app.closeLease()
	})
	return app.closeErr
}

func (app *App) Cancelled() bool {
	return app.phase == phaseSetup && app.setup.cancelled
}

func (app *App) Detached() bool {
	return app.phase == phaseLive && app.live.detached
}

func (app *App) FocusTargetRequested() bool {
	return app.phase == phaseLive && app.live.focusTarget
}

func (app *App) StartupError() error { return app.startupError }

func (app *App) View() tea.View {
	content := ""
	switch app.phase {
	case phaseLive:
		content = app.live.View()
	default:
		content = app.setup.View()
	}
	view := tea.NewView(content)
	view.AltScreen = true
	view.MouseMode = tea.MouseModeCellMotion
	return view
}
