package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

var liveViewNames = []string{"Timeline", "Decision", "Screen", "Config", "Logs"}

func (model *LiveModel) refreshViewport() {
	offset := model.viewport.YOffset()
	model.viewport.SetContentLines(model.contentLines())
	if model.activeView == ViewTimeline && model.timelineFollow {
		model.viewport.GotoBottom()
	} else {
		model.viewport.SetYOffset(offset)
	}
}

func (model LiveModel) contentLines() []string {
	if model.showHelp {
		return []string{
			setupStyles.group.Render("Live controls"),
			"1-5                switch evidence view",
			"j/k or arrows      scroll and select",
			"g / G              first / last; G resumes follow",
			"e                  expand a Timeline group",
			"p                  pause or resume",
			"r                  reassess now",
			"k                  keep completed console open",
			"c                  open Config",
			"Enter              target focus; popup detach",
			"q                  stop active run or close terminal run",
			"?                  close help",
		}
	}
	switch model.activeView {
	case ViewDecision:
		return model.decisionLines()
	case ViewScreen:
		return model.screenLines()
	case ViewConfig:
		return configLines(model.snapshot.Config)
	case ViewLogs:
		return model.logLines()
	default:
		return model.timelineLines()
	}
}

func (model LiveModel) timelineLines() []string {
	if len(model.groups) == 0 {
		return []string{setupStyles.muted.Render("Waiting for the first canonical event")}
	}
	var lines []string
	for index, group := range model.groups {
		prefix := "  "
		if index == model.selectedGroup {
			prefix = setupStyles.focus.Render("› ")
		}
		event := group.Events[len(group.Events)-1]
		line := prefix + formatEvent(event)
		if group.Count > 1 {
			line += setupStyles.provenance.Render(fmt.Sprintf("  ×%d", group.Count))
		}
		lines = append(lines, line)
		if group.Expanded {
			for eventIndex, member := range group.Events {
				lines = append(lines, fmt.Sprintf("    #%d %s", eventIndex+1, formatEvent(member)))
			}
		}
	}
	return lines
}

func formatEvent(event runmodel.Event) string {
	timestamp := event.Timestamp
	if parsed, err := time.Parse(time.RFC3339, timestamp); err == nil {
		timestamp = parsed.Format("15:04:05")
	}
	if timestamp == "" {
		timestamp = "--:--:--"
	}
	kind := strings.ToUpper(firstNonEmpty(event.Kind, event.Phase, event.Record, "event"))
	summary := firstNonEmpty(event.Label, event.Status, event.Reason, event.Text)
	if event.Error != nil {
		severity := "ERROR"
		if event.Error.Class == "config-permanent" {
			severity = "PERMANENT"
		}
		summary = fmt.Sprintf("[%s %s] %s", severity, event.Error.Code,
			firstNonEmpty(event.Error.Summary, event.Error.Detail, summary))
	}
	return fmt.Sprintf("%s  %-16s %s", timestamp, kind, summary)
}

func (model LiveModel) decisionLines() []string {
	if model.details.Decision == nil && model.details.DecisionMeta == nil {
		return []string{setupStyles.muted.Render("No model decision has been persisted yet")}
	}
	var lines []string
	if meta := model.details.DecisionMeta; meta != nil {
		lines = append(lines,
			setupStyles.group.Render(fmt.Sprintf("Call %d", meta.Call)),
			fmt.Sprintf("Model      %s / %s", firstNonEmpty(meta.Model, "profile-managed"), firstNonEmpty(meta.Effort, "profile-managed")),
			fmt.Sprintf("Backend    %s · rc=%d · %.1fs", meta.Backend, meta.BackendRC, meta.Elapsed),
			fmt.Sprintf("Policy     %s · autonomy %s", meta.Policy, meta.Autonomy),
		)
		if !meta.SchemaValid {
			lines = append(lines, setupStyles.danger.Render("Validation  "+firstNonEmpty(meta.SchemaError, "invalid model output")))
		}
	}
	if decision := model.details.Decision; decision != nil {
		lines = append(lines,
			"",
			setupStyles.group.Render("Assessment"),
			fmt.Sprintf("Pane       %s", decision.PaneState),
			fmt.Sprintf("Goal       %s", decision.GoalStatus),
			fmt.Sprintf("Risk       %s", decision.Risk),
		)
		for _, evidence := range decision.Evidence {
			lines = append(lines, "Evidence   "+evidence)
		}
		lines = append(lines,
			"",
			setupStyles.group.Render("Action"),
			fmt.Sprintf("Decision   %s · safe=%v", decision.Action, decision.Safe),
			"Reason     "+decision.Reason,
			fmt.Sprintf("Text       %q", decision.Text),
			fmt.Sprintf("Keys       %s", strings.Join(decision.Keys, ", ")),
		)
	} else if model.details.DecisionRaw != "" {
		lines = append(lines, "", setupStyles.danger.Render("Raw invalid output"), model.details.DecisionRaw)
	}
	return lines
}

func (model LiveModel) screenLines() []string {
	config := model.snapshot.Config
	lines := []string{
		setupStyles.group.Render("Model screen evidence"),
		fmt.Sprintf("Fallback capture    %d lines", config.Values.FallbackCaptureLines.Value),
		fmt.Sprintf("Configured capture  %d lines", config.Values.CaptureLines.Value),
		fmt.Sprintf("Console excerpt     %d lines", config.Values.MonitorExcerptLines.Value),
	}
	if model.details.ScreenPath != "" {
		lines = append(lines, "Path                "+model.details.ScreenPath, "")
		lines = append(lines, strings.Split(strings.TrimSuffix(model.details.Screen, "\n"), "\n")...)
		return lines
	}
	lines = append(lines, "", setupStyles.muted.Render(
		"Screen content was not persisted for this call. Enable full logging or screen snapshots for durable capture evidence."))
	return lines
}

func configLines(config runmodel.Config) []string {
	lines := []string{
		setupStyles.group.Render("Intent"),
		"Goal                      " + config.Goal,
		setupStyles.group.Render("Authority"),
	}
	appendValue := func(label, value string, source runmodel.Source) {
		lines = append(lines, fmt.Sprintf("%-25s %-18s %s", label, value, source))
	}
	v := config.Values
	appendValue("Approval policy", v.ApprovalPolicy.Value, v.ApprovalPolicy.Source)
	appendValue("Autonomy", v.Autonomy.Value, v.Autonomy.Source)
	appendValue("Always allow", v.AlwaysAllow.Value, v.AlwaysAllow.Source)
	lines = append(lines, setupStyles.group.Render("Triggering"))
	appendValue("Hooks first", v.HooksFirst.Value, v.HooksFirst.Source)
	appendValue("Idle interval", fmt.Sprintf("%gs", v.Poll.Value), v.Poll.Source)
	appendValue("Stable samples", fmt.Sprint(v.StableScreenThreshold.Value), v.StableScreenThreshold.Source)
	lines = append(lines, setupStyles.group.Render("Brain"))
	appendValue("Command", emptyLabel(v.Command.Value), v.Command.Source)
	appendValue("Profile", emptyLabel(v.Profile.Value), v.Profile.Source)
	appendValue("Model", emptyLabel(v.Model.Value), v.Model.Source)
	appendValue("Effort", emptyLabel(v.Effort.Value), v.Effort.Source)
	appendValue("Timeout", fmt.Sprintf("%ds", v.Timeout.Value), v.Timeout.Source)
	lines = append(lines, setupStyles.group.Render("Budget"))
	appendValue("Decision limit", fmt.Sprint(v.MaxDecisions.Value), v.MaxDecisions.Source)
	appendValue("Retry limit", fmt.Sprint(v.RetryLimit.Value), v.RetryLimit.Source)
	appendValue("Retry backoff", fmt.Sprintf("%ds", v.RetryBackoff.Value), v.RetryBackoff.Source)
	lines = append(lines, setupStyles.group.Render("Context"))
	appendValue("Fallback capture", fmt.Sprint(v.FallbackCaptureLines.Value), v.FallbackCaptureLines.Source)
	appendValue("Capture lines", fmt.Sprint(v.CaptureLines.Value), v.CaptureLines.Source)
	appendValue("Screen excerpt", fmt.Sprint(v.MonitorExcerptLines.Value), v.MonitorExcerptLines.Source)
	lines = append(lines, setupStyles.group.Render("Console"))
	appendValue("Monitor position", v.MonitorPosition.Value, v.MonitorPosition.Source)
	appendValue("Monitor width", fmt.Sprint(v.MonitorWidth.Value), v.MonitorWidth.Source)
	appendValue("Overview ratio", fmt.Sprintf("%d%%", v.OverviewRatio.Value), v.OverviewRatio.Source)
	appendValue("Close delay", fmt.Sprintf("%ds", v.CompletionCloseDelay.Value), v.CompletionCloseDelay.Source)
	lines = append(lines, setupStyles.group.Render("Logging"))
	appendValue("Logging", v.Logging.Value, v.Logging.Source)
	appendValue("Screen snapshots", v.ScreenSnapshots.Value, v.ScreenSnapshots.Source)
	appendValue("Retention", fmt.Sprintf("%d days", v.RetentionDays.Value), v.RetentionDays.Source)
	if config.Backend != nil {
		lines = append(lines, setupStyles.group.Render("Resolved backend"),
			"Mode                      "+config.Backend.Mode,
			"Path                      "+config.Backend.Path,
			"Version                   "+config.Backend.Version,
			"Identity                  "+config.Backend.Identity,
		)
	}
	return lines
}

func emptyLabel(value string) string {
	if value == "" {
		return "not set"
	}
	return value
}

func (model LiveModel) logLines() []string {
	lines := []string{
		setupStyles.group.Render("Run files"),
		"Root  " + model.runDir,
	}
	for _, artifact := range model.details.Files {
		lines = append(lines, fmt.Sprintf("%-40s %8d B", artifact.Path, artifact.Size))
	}
	if model.details.StderrPath != "" {
		lines = append(lines, "", setupStyles.group.Render("Latest backend stderr"),
			"Path  "+model.details.StderrPath)
		if model.details.Stderr == "" {
			lines = append(lines, setupStyles.muted.Render("<empty>"))
		} else {
			lines = append(lines, strings.Split(strings.TrimSuffix(model.details.Stderr, "\n"), "\n")...)
		}
	}
	if model.snapshot.Final != nil {
		lines = append(lines, "", setupStyles.group.Render("Final report"),
			"Outcome  "+model.snapshot.Final.Outcome,
			"Reason   "+model.snapshot.Final.Reason,
			"Log      "+model.snapshot.Final.LogPath,
		)
	}
	return lines
}

func (model LiveModel) View() string {
	width := max(20, model.width)
	height := max(10, model.height)
	header := model.liveHeader(width)
	footer := model.liveFooter(width)
	content := strings.Split(model.viewport.View(), "\n")
	lines := make([]string, 0, height)
	lines = append(lines, header...)
	lines = append(lines, content...)
	for len(lines)+len(footer) < height {
		lines = append(lines, "")
	}
	lines = append(lines, footer...)
	if len(lines) > height {
		lines = lines[:height]
	}
	for index, line := range lines {
		lines[index] = fitLine(line, width)
	}
	return strings.Join(lines, "\n")
}

func (model LiveModel) liveHeader(width int) []string {
	phase := "LOADING"
	status := "waiting for run state"
	if model.snapshot.State != nil {
		phase = firstNonEmpty(model.snapshot.State.Phase, phase)
		status = firstNonEmpty(model.snapshot.State.Status, status)
	}
	if model.snapshot.Final != nil {
		phase = strings.ToUpper(model.snapshot.Final.Outcome)
		status = model.snapshot.Final.Reason
	}
	title := setupStyles.title.Render("tmux-radar supervisor") + "  " + setupStyles.phase.Render(phase) +
		setupStyles.muted.Render("  run "+model.runID)
	goal := "Goal  " + firstNonEmpty(model.snapshot.Config.Goal, "loading")
	nowLine := "Now   " + status
	nextLine := model.nextLine()
	if backendError := model.currentBackendError(); backendError != nil {
		severity := "ERROR"
		if backendError.Class == "config-permanent" {
			severity = "PERMANENT"
		}
		nowLine = fmt.Sprintf("Now   %s %s · %s", severity, backendError.Code,
			firstNonEmpty(backendError.Summary, backendError.Detail, status))
		if model.snapshot.Final != nil {
			nextLine = "Next  start supervision again after fixing · 5 Logs · " +
				firstNonEmpty(backendError.Detail, "fix the backend configuration")
		} else if phase == "PAUSED_ERROR" {
			nextLine = "Next  " + firstNonEmpty(backendError.Detail,
				"fix the backend configuration") + " · r reassess · 5 Logs"
		} else {
			nextLine += " · 5 Logs"
		}
	}
	tabs := model.renderTabs(width)
	return []string{
		fitLine(title, width), fitLine(goal, width), fitLine(nowLine, width),
		fitLine(nextLine, width), fitLine(tabs, width), fitLine(strings.Repeat("─", width), width),
	}
}

func (model LiveModel) currentBackendError() *runmodel.BackendError {
	if model.snapshot.State == nil || model.snapshot.State.LatestErrorEventID == "" {
		return nil
	}
	status := strings.ToLower(model.snapshot.State.Status)
	if model.snapshot.State.Phase != "PAUSED_ERROR" && !strings.Contains(status, "backend") {
		return nil
	}
	for index := len(model.events) - 1; index >= 0; index-- {
		event := model.events[index]
		if event.EventID == model.snapshot.State.LatestErrorEventID && event.Error != nil {
			return event.Error
		}
	}
	return nil
}

func (model LiveModel) nextLine() string {
	if model.pending != nil {
		return "Next  waiting for " + model.pending.Action + " acknowledgement"
	}
	if model.snapshot.Final != nil {
		if model.completionKept {
			return "Next  report kept open; q closes this console"
		}
		if !model.completionDeadline.IsZero() {
			remaining := int(time.Until(model.completionDeadline).Seconds())
			if remaining < 0 {
				remaining = 0
			}
			return fmt.Sprintf("Next  close console in %ds; k keeps it open", remaining)
		}
		return "Next  terminal report available in Logs"
	}
	if model.snapshot.State != nil && model.snapshot.State.Next.At > 0 {
		remaining := model.snapshot.State.Next.At - model.now.Unix()
		if remaining < 0 {
			remaining = 0
		}
		return fmt.Sprintf("Next  %s in %ds", model.snapshot.State.Next.Kind, remaining)
	}
	return "Next  native event or stable-screen fallback"
}

func (model LiveModel) renderTabs(width int) string {
	if width < 56 {
		return "1:T  2:D  3:S  4:C  5:L"
	}
	parts := make([]string, 0, liveViewCount)
	for index, name := range liveViewNames {
		label := fmt.Sprintf("%d %s", index+1, name)
		if LiveView(index) == model.activeView {
			label = setupStyles.focused.Render("[" + label + "]")
		}
		parts = append(parts, label)
	}
	return strings.Join(parts, "  ")
}

func (model LiveModel) liveFooter(width int) []string {
	controls := "1-5 views · j/k scroll · e expand · p pause · r reassess · k keep · Enter target · q stop · ? help"
	if model.snapshot.Final != nil {
		controls = "1-5 views · j/k scroll · e expand · k keep · Enter target · q close · ? help"
		if width < 56 {
			controls = "1-5 view · k · Enter · q · ?"
		} else if width < 72 {
			controls = "1-5 · k keep · Enter target · q close · ?"
		} else if width < 110 {
			controls = "1-5 · j/k · e · k · Enter · q · ?"
		}
	} else if width < 56 {
		controls = "1-5 view · p · r · Enter · q · ?"
	} else if width < 72 {
		controls = "1-5 · p pause · r redo · Enter target · q stop · ?"
	} else if width < 110 {
		controls = "1-5 · j/k · e · p · r · k · Enter · q · ?"
	}
	message := model.controlNotice
	if model.controlError != "" {
		message = setupStyles.danger.Render(model.controlError)
	} else if model.confirmStop {
		message = setupStyles.warning.Render("Stop supervision? y confirm · n cancel")
	} else if model.activeView == ViewTimeline && model.newEvents > 0 {
		message = setupStyles.warning.Render(fmt.Sprintf("%d new events · G follow", model.newEvents))
	}
	return []string{fitLine(setupStyles.muted.Render(controls), width), fitLine(message, width)}
}

func liveChromeRows(_ int) int { return 8 }
