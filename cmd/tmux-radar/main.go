package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/lr00rl/tmux-radar/internal/enginebridge"
	"github.com/lr00rl/tmux-radar/internal/preflight"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
	"github.com/lr00rl/tmux-radar/internal/tui"
)

const (
	exitOK        = 0
	exitUsage     = 2
	exitPermanent = 3
	exitEngine    = 4
	exitProtocol  = 5
)

var (
	buildVersion = "dev"
	buildCommit  = "unknown"
	buildDate    = "unknown"
)

type programRunner func(context.Context, *tui.App, io.Reader, io.Writer) (tea.Model, error)

var launchProgram programRunner = func(ctx context.Context, app *tui.App, input io.Reader, output io.Writer) (tea.Model, error) {
	program := tea.NewProgram(app, tea.WithContext(ctx), tea.WithInput(input), tea.WithOutput(output))
	return program.Run()
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(ctx context.Context, args []string, input io.Reader, output, errorOutput io.Writer) int {
	if len(args) == 0 {
		printUsage(errorOutput)
		return exitUsage
	}
	switch args[0] {
	case "version", "--version", "-version":
		if len(args) != 1 {
			fmt.Fprintln(errorOutput, "version does not accept arguments")
			return exitUsage
		}
		fmt.Fprintf(output, "tmux-radar %s (commit %s, built %s, protocol %d, schema %d)\n",
			buildVersion, buildCommit, buildDate, runmodel.CurrentProtocolVersion, runmodel.CurrentSchemaVersion)
		return exitOK
	case "supervisor":
		return runSupervisor(ctx, args[1:], input, output, errorOutput)
	default:
		fmt.Fprintf(errorOutput, "unknown command %q\n", args[0])
		printUsage(errorOutput)
		return exitUsage
	}
}

func runSupervisor(ctx context.Context, args []string, input io.Reader, output, errorOutput io.Writer) int {
	if len(args) == 0 {
		printSupervisorUsage(errorOutput)
		return exitUsage
	}
	switch args[0] {
	case "doctor":
		return runDoctor(ctx, args[1:], output, errorOutput)
	case "setup":
		return runSetup(ctx, args[1:], input, output, errorOutput)
	case "attach":
		return runAttach(ctx, args[1:], input, output, errorOutput)
	default:
		fmt.Fprintf(errorOutput, "unknown supervisor command %q\n", args[0])
		printSupervisorUsage(errorOutput)
		return exitUsage
	}
}

func runDoctor(ctx context.Context, args []string, output, errorOutput io.Writer) int {
	flags := newFlagSet("tmux-radar supervisor doctor", errorOutput)
	jsonOutput := flags.Bool("json", false, "emit machine-readable JSON")
	enginePath := flags.String("engine-script", "", "path to scripts/ai.sh")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err)
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(errorOutput, "doctor does not accept positional arguments")
		return exitUsage
	}
	resolvedEngine, err := resolveEngineScript(*enginePath)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitPermanent
	}
	result, err := (preflight.Checker{EngineScript: resolvedEngine}).Check(ctx)
	if err != nil {
		if *jsonOutput {
			_ = json.NewEncoder(output).Encode(map[string]any{
				"ok": false, "class": "doctor-failed", "summary": err.Error(),
			})
		} else {
			fmt.Fprintf(errorOutput, "Supervisor preflight failed: %v\n", err)
		}
		return classifyError(err, exitPermanent)
	}
	if *jsonOutput {
		if err := json.NewEncoder(output).Encode(result); err != nil {
			fmt.Fprintf(errorOutput, "encode doctor result: %v\n", err)
			return exitEngine
		}
	} else {
		printDoctorResult(output, result)
	}
	if !result.OK {
		return exitPermanent
	}
	return exitOK
}

func runSetup(ctx context.Context, args []string, input io.Reader, output, errorOutput io.Writer) int {
	flags := newFlagSet("tmux-radar supervisor setup", errorOutput)
	targetPane := flags.String("target-pane", "", "target tmux pane ID")
	monitorPane := flags.String("monitor-pane", "", "supervisor tmux pane ID")
	surfaceValue := flags.String("surface", string(tui.SurfaceSplit), "split or popup")
	entryValue := flags.String("entry", string(tui.EntryQuick), "quick, always-allow, or advanced")
	enginePath := flags.String("engine-script", "", "path to scripts/ai.sh")
	statePath := flags.String("state-root", "", "absolute supervisor state root")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err)
	}
	if flags.NArg() != 0 || *targetPane == "" {
		fmt.Fprintln(errorOutput, "setup requires --target-pane and no positional arguments")
		return exitUsage
	}
	surface, err := parseSurface(*surfaceValue)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitUsage
	}
	entry, err := parseEntry(*entryValue)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitUsage
	}
	if surface == tui.SurfaceSplit && *monitorPane == "" {
		fmt.Fprintln(errorOutput, "split setup requires --monitor-pane")
		return exitUsage
	}
	stateRoot, err := resolveStateRoot(*statePath)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitPermanent
	}
	resolvedEngine, err := resolveEngineScript(*enginePath)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitPermanent
	}
	environment := []string{"TMUX_RADAR_STATE_DIR=" + stateRoot}
	checker := &preflight.Checker{EngineScript: resolvedEngine, Env: environment}
	bridge := &enginebridge.Bridge{EngineScript: resolvedEngine, Env: environment}
	app := tui.NewApp(tui.AppOptions{
		Setup: tui.SetupOptions{TargetPane: *targetPane, Entry: entry}, Checker: checker, Engine: bridge,
		StateRoot: stateRoot, MonitorPane: *monitorPane, Surface: surface,
		FocusTarget: focusTmuxPane(*targetPane),
	})
	_, programErr := launchProgram(ctx, app, input, output)
	closeErr := app.Close()
	if programErr != nil {
		fmt.Fprintf(errorOutput, "supervisor TUI failed: %v\n", programErr)
		return classifyError(programErr, exitEngine)
	}
	if closeErr != nil {
		fmt.Fprintln(errorOutput, closeErr)
		return exitEngine
	}
	if startupErr := app.StartupError(); startupErr != nil {
		fmt.Fprintf(errorOutput, "supervisor start failed: %v\n", startupErr)
		return classifyError(startupErr, exitEngine)
	}
	return exitOK
}

func focusTmuxPane(targetPane string) func(context.Context) error {
	return func(ctx context.Context) error {
		focusContext, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		command := exec.CommandContext(focusContext, "tmux", "select-pane", "-t", targetPane)
		var stderr strings.Builder
		command.Stderr = &stderr
		if err := command.Run(); err != nil {
			return fmt.Errorf("tmux select-pane: %w: %s", err, strings.TrimSpace(stderr.String()))
		}
		return nil
	}
}

func runAttach(ctx context.Context, args []string, input io.Reader, output, errorOutput io.Writer) int {
	flags := newFlagSet("tmux-radar supervisor attach", errorOutput)
	runID := flags.String("run", "", "canonical run ID")
	statePath := flags.String("state-root", "", "absolute supervisor state root")
	enginePath := flags.String("engine-script", "", "accepted for launcher compatibility")
	if err := flags.Parse(args); err != nil {
		return flagExitCode(err)
	}
	if flags.NArg() != 0 || !validRunID(*runID) {
		fmt.Fprintln(errorOutput, "attach requires a simple --run ID and no positional arguments")
		return exitUsage
	}
	_ = enginePath
	stateRoot, err := resolveStateRoot(*statePath)
	if err != nil {
		fmt.Fprintln(errorOutput, err)
		return exitPermanent
	}
	runDir := filepath.Join(stateRoot, "ai-runs", *runID)
	app, err := tui.NewLiveApp(tui.LiveOptions{
		RunDir: runDir, RunID: *runID, Surface: tui.SurfaceSplit, ReadOnly: true,
	})
	if err != nil {
		fmt.Fprintf(errorOutput, "attach run %q: %v\n", *runID, err)
		return classifyError(err, exitPermanent)
	}
	_, programErr := launchProgram(ctx, app, input, output)
	closeErr := app.Close()
	if programErr != nil {
		fmt.Fprintf(errorOutput, "attached TUI failed: %v\n", programErr)
		return classifyError(programErr, exitEngine)
	}
	if closeErr != nil {
		fmt.Fprintln(errorOutput, closeErr)
		return exitEngine
	}
	return exitOK
}

func newFlagSet(name string, output io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(output)
	return flags
}

func flagExitCode(err error) int {
	if errors.Is(err, flag.ErrHelp) {
		return exitOK
	}
	return exitUsage
}

func parseSurface(value string) (tui.Surface, error) {
	surface := tui.Surface(value)
	if surface != tui.SurfaceSplit && surface != tui.SurfacePopup {
		return "", fmt.Errorf("unsupported surface %q (want split or popup)", value)
	}
	return surface, nil
}

func parseEntry(value string) (tui.EntryMode, error) {
	entry := tui.EntryMode(value)
	if entry != tui.EntryQuick && entry != tui.EntryAlwaysAllow && entry != tui.EntryAdvanced {
		return "", fmt.Errorf("unsupported entry %q (want quick, always-allow, or advanced)", value)
	}
	return entry, nil
}

func resolveStateRoot(explicit string) (string, error) {
	root := explicit
	if root == "" {
		root = os.Getenv("TMUX_RADAR_STATE_DIR")
	}
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve state root: %w", err)
		}
		root = filepath.Join(home, ".local", "state", "tmux")
	}
	if !filepath.IsAbs(root) {
		return "", errors.New("state root must be an absolute path")
	}
	return filepath.Clean(root), nil
}

func resolveEngineScript(explicit string) (string, error) {
	candidates := make([]string, 0, 3)
	if explicit != "" {
		candidates = append(candidates, explicit)
	} else if fromEnvironment := os.Getenv("TMUX_RADAR_ENGINE_SCRIPT"); fromEnvironment != "" {
		candidates = append(candidates, fromEnvironment)
	} else if executable, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(executable), "..", "scripts", "ai.sh"))
	}
	for _, candidate := range candidates {
		absolute, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		info, err := os.Stat(absolute)
		if err == nil && !info.IsDir() {
			return filepath.Clean(absolute), nil
		}
	}
	return "", errors.New("cannot locate scripts/ai.sh; pass --engine-script or TMUX_RADAR_ENGINE_SCRIPT")
}

func validRunID(value string) bool {
	return value != "" && value != "." && value != ".." && filepath.Base(value) == value &&
		!strings.ContainsAny(value, `/\\`)
}

func classifyError(err error, fallback int) int {
	if err != nil && strings.Contains(strings.ToLower(err.Error()), "protocol mismatch") {
		return exitProtocol
	}
	return fallback
}

func printDoctorResult(output io.Writer, result preflight.Result) {
	status := "READY"
	if !result.OK {
		status = "BLOCKED"
	}
	fmt.Fprintf(output, "Supervisor preflight: %s\n", status)
	fmt.Fprintf(output, "Backend: %s %s\n", result.Backend.Mode, firstNonEmpty(result.Backend.Version, "unknown"))
	fmt.Fprintf(output, "Brain: model=%s effort=%s\n", result.Model, result.Effort)
	if result.Summary != "" {
		fmt.Fprintln(output, result.Summary)
	}
	if result.Detail != "" {
		fmt.Fprintln(output, result.Detail)
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func printUsage(output io.Writer) {
	fmt.Fprintln(output, "usage: tmux-radar version | tmux-radar supervisor <doctor|setup|attach> [options]")
}

func printSupervisorUsage(output io.Writer) {
	fmt.Fprintln(output, "usage: tmux-radar supervisor <doctor|setup|attach> [options]")
}
