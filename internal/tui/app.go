package tui

import (
	"context"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/preflight"
)

type AppOptions struct {
	Setup   SetupOptions
	Checker *preflight.Checker
}

type App struct {
	setup   SetupModel
	checker *preflight.Checker
}

func NewApp(options AppOptions) App {
	app := App{setup: NewSetup(options.Setup), checker: options.Checker}
	if app.checker != nil {
		app.setup.beginPreflight()
	}
	return app
}

func (app App) Init() tea.Cmd {
	if app.checker == nil {
		return nil
	}
	return runPreflight(*app.checker, app.setup.preflightRequestID)
}

func runPreflight(checker preflight.Checker, requestID uint64) tea.Cmd {
	return func() tea.Msg {
		result, err := checker.Check(context.Background())
		return PreflightResultMsg{RequestID: requestID, Result: result, Err: err}
	}
}

func (app App) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	previousRequestID := app.setup.preflightRequestID
	updated, command := app.setup.Update(message)
	app.setup = updated
	if app.checker != nil && app.setup.preflightRequestID != previousRequestID {
		command = tea.Batch(command, runPreflight(*app.checker, app.setup.preflightRequestID))
	}
	return app, command
}

func (app App) View() tea.View { return tea.NewView(app.setup.View()) }
