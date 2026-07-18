package tui

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/lr00rl/tmux-radar/internal/preflight"
	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

type preflightState string

const (
	preflightPending  preflightState = "pending"
	preflightReady    preflightState = "ready"
	preflightBlocking preflightState = "blocking"
)

type SetupOptions struct {
	TargetPane string
	Entry      EntryMode
	Config     *runmodel.Config
	Preflight  *preflight.Result
}

type PreflightResultMsg struct {
	RequestID uint64
	Result    preflight.Result
	Err       error
}

type focusTarget struct {
	ID    string
	Group bool
}

type SetupModel struct {
	targetPane string
	config     runmodel.Config
	entry      EntryMode
	preset     Preset
	advanced   bool
	groups     map[string]bool
	goal       textarea.Model
	inputs     map[string]textinput.Model
	errors     map[string]string
	focus      []focusTarget
	focusIndex int
	editing    bool
	width      int
	height     int
	showHelp   bool

	preflightStatus    preflightState
	preflightResult    preflight.Result
	preflightError     string
	preflightRequestID uint64
	blockingError      string
	launchRequested    bool
	cancelled          bool
}

func NewSetup(options SetupOptions) SetupModel {
	if options.TargetPane == "" {
		options.TargetPane = "%0"
	}
	config := runmodel.DefaultConfig(options.TargetPane, "")
	if options.Config != nil {
		config = *options.Config
		config.Pane = options.TargetPane
	}

	goal := textarea.New()
	goal.Prompt = ""
	goal.Placeholder = runmodel.DefaultGoal
	goal.ShowLineNumbers = false
	goal.CharLimit = 16 * 1024
	goal.MaxHeight = 4
	goal.SetHeight(3)
	goal.SetWidth(72)
	if config.Values.Goal.Source != runmodel.SourceDefault || config.Goal != runmodel.DefaultGoal {
		goal.SetValue(config.Goal)
	}

	model := SetupModel{
		targetPane:         options.TargetPane,
		config:             config,
		entry:              options.Entry,
		preset:             PresetDefault,
		groups:             make(map[string]bool, len(advancedGroupOrder)),
		goal:               goal,
		inputs:             make(map[string]textinput.Model),
		errors:             make(map[string]string),
		width:              84,
		height:             40,
		preflightStatus:    preflightPending,
		blockingError:      "Preflight is still running",
		launchRequested:    false,
		preflightRequestID: 1,
	}
	for _, spec := range advancedFields {
		if spec.Kind != kindText && spec.Kind != kindInt && spec.Kind != kindFloat {
			continue
		}
		input := textinput.New()
		input.Prompt = ""
		input.SetWidth(32)
		input.SetValue(model.fieldValue(spec.ID))
		model.inputs[spec.ID] = input
	}

	switch options.Entry {
	case EntryAlwaysAllow:
		model.preset = PresetAlwaysAllow
		model.applyPreset(PresetAlwaysAllow, true)
	case EntryAdvanced:
		model.advanced = true
		for _, group := range advancedGroupOrder {
			model.groups[group] = true
		}
	default:
		model.entry = EntryQuick
	}
	if options.Preflight != nil {
		model.applyPreflight(*options.Preflight, nil)
	}
	model.rebuildFocus()
	model.setFocus(fieldGoal)
	return model
}

func (model *SetupModel) beginPreflight() uint64 {
	model.preflightRequestID++
	model.preflightStatus = preflightPending
	model.preflightError = ""
	model.blockingError = "Preflight is still running"
	model.launchRequested = false
	return model.preflightRequestID
}

func (model *SetupModel) applyPreflight(result preflight.Result, err error) {
	model.preflightResult = result
	if err != nil {
		model.preflightStatus = preflightBlocking
		model.preflightError = err.Error()
		model.blockingError = "Preflight failed: " + err.Error()
		return
	}
	if !result.OK {
		model.preflightStatus = preflightBlocking
		model.preflightError = firstNonEmpty(result.Summary, result.Detail, "backend is not ready")
		model.blockingError = "Preflight blocked: " + model.preflightError
		return
	}
	model.preflightStatus = preflightReady
	model.preflightError = ""
	model.blockingError = ""
}

func (model SetupModel) Init() tea.Cmd { return nil }

func (model SetupModel) Update(message tea.Msg) (SetupModel, tea.Cmd) {
	switch message := message.(type) {
	case tea.WindowSizeMsg:
		model.resize(message.Width, message.Height)
		return model, nil
	case PreflightResultMsg:
		if message.RequestID == model.preflightRequestID {
			model.applyPreflight(message.Result, message.Err)
		}
		return model, nil
	case tea.PasteMsg:
		return model.updateEditor(message)
	case tea.KeyPressMsg:
		if model.showHelp {
			switch message.String() {
			case "?", "esc", "q":
				model.showHelp = false
			}
			return model, nil
		}
		if message.String() == "ctrl+c" {
			model.cancelled = true
			return model, tea.Quit
		}
		switch message.String() {
		case "tab":
			if model.commitBeforeMove() {
				model.moveFocus(1)
			}
			return model, nil
		case "shift+tab":
			if model.commitBeforeMove() {
				model.moveFocus(-1)
			}
			return model, nil
		}
		if model.editing {
			return model.updateEditor(message)
		}
		return model.updateControl(message)
	}
	return model, nil
}

func (model SetupModel) updateEditor(message tea.Msg) (SetupModel, tea.Cmd) {
	id := model.focusedID()
	if key, ok := message.(tea.KeyPressMsg); ok {
		switch key.String() {
		case "esc":
			if id == fieldGoal {
				model.goal.Blur()
			} else if input, exists := model.inputs[id]; exists {
				input.SetValue(model.fieldValue(id))
				input.Blur()
				model.inputs[id] = input
			}
			model.editing = false
			delete(model.errors, id)
			return model, nil
		case "enter":
			if id != fieldGoal {
				if !model.commitInput(id) {
					return model, nil
				}
				model.editing = false
				return model, nil
			}
		}
	}
	if id == fieldGoal {
		updated, command := model.goal.Update(message)
		model.goal = updated
		model.launchRequested = false
		return model, command
	}
	input, exists := model.inputs[id]
	if !exists {
		return model, nil
	}
	updated, command := input.Update(message)
	model.inputs[id] = updated
	return model, command
}

func (model SetupModel) updateControl(message tea.KeyPressMsg) (SetupModel, tea.Cmd) {
	id := model.focusedID()
	switch message.String() {
	case "?":
		model.showHelp = true
		return model, nil
	case "q":
		model.cancelled = true
		return model, tea.Quit
	case "enter":
		switch {
		case id == fieldGoal:
			model.editing = true
			return model, model.goal.Focus()
		case id == fieldPreset:
			model.cyclePreset(1)
		case id == fieldApproval:
			model.cycleBasicField(id, 1)
		case id == fieldAutonomy:
			model.cycleBasicField(id, 1)
		case id == fieldAdvanced:
			model.advanced = !model.advanced
			model.rebuildFocus()
		case strings.HasPrefix(id, "group:"):
			group := strings.TrimPrefix(id, "group:")
			model.groups[group] = !model.groups[group]
			model.rebuildFocus()
		case id == fieldStart:
			model.requestLaunch()
		default:
			spec, ok := fieldByID(id)
			if !ok {
				break
			}
			switch spec.Kind {
			case kindEnum:
				model.cycleField(spec, 1)
			case kindToggle:
				model.toggleField(id)
			default:
				model.beginEdit(id)
			}
		}
	case "left", "h":
		if id == fieldPreset {
			model.cyclePreset(-1)
		} else if id == fieldApproval || id == fieldAutonomy {
			model.cycleBasicField(id, -1)
		} else if spec, ok := fieldByID(id); ok && spec.Kind == kindEnum {
			model.cycleField(spec, -1)
		}
	case "right", "l":
		if id == fieldPreset {
			model.cyclePreset(1)
		} else if id == fieldApproval || id == fieldAutonomy {
			model.cycleBasicField(id, 1)
		} else if spec, ok := fieldByID(id); ok && spec.Kind == kindEnum {
			model.cycleField(spec, 1)
		}
	case " ", "space":
		if spec, ok := fieldByID(id); ok && spec.Kind == kindToggle {
			model.toggleField(id)
		}
	}
	return model, nil
}

func (model *SetupModel) commitBeforeMove() bool {
	if !model.editing {
		return true
	}
	id := model.focusedID()
	if id != fieldGoal && !model.commitInput(id) {
		return false
	}
	model.goal.Blur()
	if input, exists := model.inputs[id]; exists {
		input.Blur()
		model.inputs[id] = input
	}
	model.editing = false
	return true
}

func (model *SetupModel) beginEdit(id string) {
	input, exists := model.inputs[id]
	if !exists {
		return
	}
	input.SetValue(model.fieldValue(id))
	input.CursorEnd()
	model.inputs[id] = input
	model.editing = true
	model.inputs[id] = focusInput(input)
	delete(model.errors, id)
}

func focusInput(input textinput.Model) textinput.Model {
	input.Focus()
	return input
}

func (model *SetupModel) commitInput(id string) bool {
	spec, ok := fieldByID(id)
	if !ok {
		return true
	}
	input := model.inputs[id]
	value := input.Value()
	var err error
	switch spec.Kind {
	case kindText:
		model.setTextField(id, value)
	case kindInt:
		var parsed int
		parsed, err = strconv.Atoi(value)
		if err == nil && (float64(parsed) < spec.Min || float64(parsed) > spec.Max) {
			err = fmt.Errorf("enter %g-%g", spec.Min, spec.Max)
		}
		if err == nil {
			model.setIntField(id, parsed)
		}
	case kindFloat:
		var parsed float64
		parsed, err = strconv.ParseFloat(value, 64)
		if err == nil && (parsed < spec.Min || parsed > spec.Max) {
			err = fmt.Errorf("enter %g-%g", spec.Min, spec.Max)
		}
		if err == nil {
			model.config.Values.Poll = runmodel.Value[float64]{Value: parsed, Source: runmodel.SourceCustom}
		}
	}
	if err != nil {
		model.errors[id] = err.Error()
		return false
	}
	delete(model.errors, id)
	input.Blur()
	model.inputs[id] = input
	model.launchRequested = false
	if id == fieldCommand || id == fieldProfile || id == fieldModel {
		model.beginPreflight()
	}
	return true
}

func (model *SetupModel) requestLaunch() {
	model.launchRequested = false
	switch model.preflightStatus {
	case preflightPending:
		model.blockingError = "Preflight is still running"
		return
	case preflightBlocking:
		model.blockingError = "Preflight blocked: " + firstNonEmpty(model.preflightError, "backend is not ready")
		return
	}
	if _, err := model.immutableConfig(); err != nil {
		model.blockingError = err.Error()
		return
	}
	model.blockingError = ""
	model.launchRequested = true
}

func (model SetupModel) immutableConfig() (runmodel.Config, error) {
	config, err := model.reviewedConfig()
	if err != nil {
		return runmodel.Config{}, err
	}
	if model.preflightStatus != preflightReady || !model.preflightResult.OK {
		return runmodel.Config{}, errors.New("preflight must pass before launch")
	}
	backend := model.preflightResult.Backend
	config.Backend = &backend
	if err := config.ValidateLaunch(); err != nil {
		return runmodel.Config{}, fmt.Errorf("launch configuration: %w", err)
	}
	return config, nil
}

func (model SetupModel) reviewedConfig() (runmodel.Config, error) {
	config := model.config
	goal := model.goal.Value()
	if goal == "" {
		goal = runmodel.DefaultGoal
		config.Values.Goal = runmodel.Value[string]{Value: goal, Source: runmodel.SourceDefault}
	} else {
		config.Values.Goal = runmodel.Value[string]{Value: goal, Source: runmodel.SourceCustom}
	}
	config.Goal = goal
	config.Pane = model.targetPane
	config.Backend = nil
	if err := config.Validate(); err != nil {
		return runmodel.Config{}, fmt.Errorf("reviewed configuration: %w", err)
	}
	return config, nil
}

func (model *SetupModel) resize(width, height int) {
	if width > 0 {
		model.width = width
	}
	if height > 0 {
		model.height = height
	}
	inputWidth := max(8, min(40, model.width-22))
	model.goal.SetWidth(max(12, model.width-4))
	for id, input := range model.inputs {
		input.SetWidth(inputWidth)
		model.inputs[id] = input
	}
}

func (model *SetupModel) rebuildFocus() {
	current := model.focusedID()
	focus := []focusTarget{{ID: fieldGoal}, {ID: fieldPreset}, {ID: fieldApproval}, {ID: fieldAutonomy}, {ID: fieldAdvanced}}
	if model.advanced {
		for _, group := range advancedGroupOrder {
			focus = append(focus, focusTarget{ID: "group:" + group, Group: true})
			if !model.groups[group] {
				continue
			}
			for _, spec := range advancedFields {
				if spec.Group == group {
					focus = append(focus, focusTarget{ID: spec.ID})
				}
			}
		}
	}
	focus = append(focus, focusTarget{ID: fieldStart})
	model.focus = focus
	model.focusIndex = 0
	for index, target := range focus {
		if target.ID == current {
			model.focusIndex = index
			break
		}
	}
}

func (model *SetupModel) setFocus(id string) {
	model.goal.Blur()
	for key, input := range model.inputs {
		input.Blur()
		model.inputs[key] = input
	}
	for index, target := range model.focus {
		if target.ID != id {
			continue
		}
		model.focusIndex = index
		model.editing = id == fieldGoal
		if model.editing {
			model.goal.Focus()
		}
		return
	}
}

func (model *SetupModel) moveFocus(delta int) {
	if len(model.focus) == 0 {
		return
	}
	model.focusIndex = (model.focusIndex + delta + len(model.focus)) % len(model.focus)
	model.setFocus(model.focus[model.focusIndex].ID)
}

func (model SetupModel) focusedID() string {
	if len(model.focus) == 0 || model.focusIndex < 0 || model.focusIndex >= len(model.focus) {
		return ""
	}
	return model.focus[model.focusIndex].ID
}

type renderedRow struct {
	ID    string
	Lines []string
}

func (model SetupModel) View() string {
	width := max(20, model.width)
	height := max(8, model.height)
	header := model.renderHeader(width)
	status := model.renderPreflight(width)
	footer := model.renderFooter(width)
	reserved := len(header) + len(status) + len(footer) + 1
	bodyHeight := max(1, height-reserved)
	rows := model.renderRows(width)
	body := visibleRows(rows, model.focusedID(), bodyHeight)

	lines := make([]string, 0, height)
	lines = append(lines, header...)
	lines = append(lines, fitLine(strings.Repeat("─", width), width))
	lines = append(lines, status...)
	lines = append(lines, body...)
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

func (model SetupModel) renderHeader(width int) []string {
	title := setupStyles.title.Render("tmux-radar supervisor") + "  " + setupStyles.phase.Render("SETUP")
	if width < 56 {
		title = setupStyles.title.Render("tmux-radar") + " · " + setupStyles.phase.Render("SETUP")
	}
	brain := model.config.Values.Model.Value + "/" + model.config.Values.Effort.Value
	if brain == "/" {
		brain = "profile-managed"
	}
	context := fmt.Sprintf("Target %s · Brain %s", model.targetPane, brain)
	return []string{fitLine(title, width), fitLine(setupStyles.muted.Render(context), width)}
}

func (model SetupModel) renderPreflight(width int) []string {
	var value string
	switch model.preflightStatus {
	case preflightReady:
		value = setupStyles.success.Render("● READY") + "  " + firstNonEmpty(model.preflightResult.Backend.Path, model.preflightResult.Backend.Mode)
	case preflightBlocking:
		value = setupStyles.danger.Render("● BLOCKED") + "  " + model.preflightError
	default:
		value = setupStyles.warning.Render("● CHECKING") + "  resolving backend compatibility"
	}
	return []string{fitLine(value, width)}
}

func (model SetupModel) renderRows(width int) []renderedRow {
	if model.showHelp {
		return model.renderHelp(width)
	}
	rows := []renderedRow{
		model.renderGoal(width),
		model.renderSimpleRow(fieldPreset, "Preset", string(model.preset), runmodel.SourcePreset, kindEnum, width),
		model.renderSimpleRow(fieldApproval, "Policy", model.config.Values.ApprovalPolicy.Value, model.config.Values.ApprovalPolicy.Source, kindEnum, width),
		model.renderSimpleRow(fieldAutonomy, "Autonomy", model.config.Values.Autonomy.Value, model.config.Values.Autonomy.Source, kindEnum, width),
	}
	changed, inherited := model.advancedCounts()
	marker := "▸"
	if model.advanced {
		marker = "▾"
	}
	rows = append(rows, renderedRow{ID: fieldAdvanced, Lines: []string{model.focusLine(fieldAdvanced,
		fmt.Sprintf("%s Advanced  %d changed · %d inherited", marker, changed, inherited), width)}})
	if model.advanced {
		for _, group := range advancedGroupOrder {
			groupID := "group:" + group
			groupMarker := "▸"
			if model.groups[group] {
				groupMarker = "▾"
			}
			rows = append(rows, renderedRow{ID: groupID, Lines: []string{model.focusLine(groupID,
				setupStyles.group.Render(groupMarker+" "+group), width)}})
			if !model.groups[group] {
				continue
			}
			if group == groupIntent {
				rows = append(rows, renderedRow{ID: groupID + ":summary", Lines: []string{
					fitLine("    Goal is edited above and preserved byte-for-byte", width),
				}})
			}
			for _, spec := range advancedFields {
				if spec.Group == group {
					rows = append(rows, model.renderField(spec, width))
				}
			}
		}
	}
	rows = append(rows, renderedRow{ID: fieldStart, Lines: []string{model.focusLine(fieldStart,
		setupStyles.start.Render("▶ Start supervision"), width)}})
	return rows
}

func (model SetupModel) renderGoal(width int) renderedRow {
	if model.editing && model.focusedID() == fieldGoal {
		lines := []string{model.focusLine(fieldGoal, "Goal", width)}
		for _, line := range strings.Split(model.goal.View(), "\n") {
			lines = append(lines, fitLine("  "+line, width))
		}
		return renderedRow{ID: fieldGoal, Lines: lines}
	}
	value := model.goal.Value()
	if value == "" {
		value = setupStyles.muted.Render(runmodel.DefaultGoal + "  [default]")
	} else {
		value = strings.ReplaceAll(value, "\n", " ↵ ")
	}
	line := model.focusLine(fieldGoal, "Goal  "+value, width)
	return renderedRow{ID: fieldGoal, Lines: []string{line}}
}

func (model SetupModel) renderField(spec fieldSpec, width int) renderedRow {
	value := model.fieldValue(spec.ID)
	if model.editing && model.focusedID() == spec.ID {
		value = model.inputs[spec.ID].View()
	} else {
		switch spec.Kind {
		case kindEnum:
			value = "‹ " + value + " ›"
		case kindToggle:
			if value == "on" {
				value = "[x] on"
			} else {
				value = "[ ] off"
			}
		case kindText:
			if value == "" {
				value = setupStyles.muted.Render("not set")
			}
		}
	}
	row := model.renderSimpleRow(spec.ID, spec.Label, value, model.fieldSource(spec.ID), spec.Kind, width)
	if message := model.errors[spec.ID]; message != "" {
		row.Lines = append(row.Lines, fitLine("    "+setupStyles.danger.Render(message), width))
	}
	return row
}

func (model SetupModel) renderSimpleRow(id, label, value string, source runmodel.Source, kind fieldKind, width int) renderedRow {
	if kind == kindEnum && id != fieldPreset && !strings.HasPrefix(value, "‹") {
		value = "‹ " + value + " ›"
	}
	labelWidth := 17
	if width < 56 {
		labelWidth = 12
	}
	content := fmt.Sprintf("%-*s %s", labelWidth, label, value)
	if width >= 56 {
		content += "  " + setupStyles.provenance.Render(string(source))
	}
	return renderedRow{ID: id, Lines: []string{model.focusLine(id, content, width)}}
}

func (model SetupModel) focusLine(id, content string, width int) string {
	prefix := "  "
	if model.focusedID() == id {
		prefix = setupStyles.focus.Render("› ")
		content = setupStyles.focused.Render(content)
	}
	return fitLine(prefix+content, width)
}

func (model SetupModel) renderHelp(width int) []renderedRow {
	lines := []string{
		setupStyles.group.Render("Setup controls"),
		"Tab / Shift-Tab   move between controls",
		"Enter             edit, select, or launch",
		"Left / Right       change an option",
		"Space              toggle on or off",
		"Esc                leave the current editor",
		"q                  cancel outside an editor",
		"?                  close this help",
	}
	rows := make([]renderedRow, 0, len(lines))
	for index, line := range lines {
		rows = append(rows, renderedRow{ID: fmt.Sprintf("help:%d", index), Lines: []string{fitLine(line, width)}})
	}
	return rows
}

func (model SetupModel) renderFooter(width int) []string {
	help := "Tab/Shift-Tab move · Enter select · ←/→ change · Space toggle · ? help · q cancel"
	if model.editing {
		help = "Tab next · Shift-Tab previous · Esc leave field"
	}
	if width < 56 {
		help = "Tab move · Enter select · ? help · q cancel"
		if model.editing {
			help = "Tab next · Esc leave field"
		}
	}
	message := ""
	if model.blockingError != "" {
		message = setupStyles.danger.Render(model.blockingError)
	} else if model.launchRequested {
		message = setupStyles.success.Render("Launch configuration is ready")
	}
	return []string{fitLine(setupStyles.muted.Render(help), width), fitLine(message, width)}
}

func visibleRows(rows []renderedRow, focusID string, height int) []string {
	if len(rows) == 0 || height <= 0 {
		return nil
	}
	focus := 0
	for index, row := range rows {
		if row.ID == focusID {
			focus = index
			break
		}
	}
	start := max(0, focus-height/2)
	for start > 0 && lineCount(rows[start:focus+1]) < height/2 {
		start--
	}
	for {
		lines := flattenRows(rows[start:])
		if len(lines) <= height {
			return lines
		}
		candidate := lines[:height]
		if rowVisible(rows, start, focus, height) {
			return candidate
		}
		start++
		if start >= len(rows) {
			return nil
		}
	}
}

func rowVisible(rows []renderedRow, start, target, height int) bool {
	if target < start {
		return false
	}
	return lineCount(rows[start:target+1]) <= height
}

func flattenRows(rows []renderedRow) []string {
	var lines []string
	for _, row := range rows {
		lines = append(lines, row.Lines...)
	}
	return lines
}

func lineCount(rows []renderedRow) int { return len(flattenRows(rows)) }

func fitLine(value string, width int) string {
	if width <= 0 {
		return ""
	}
	return ansi.Truncate(value, width, "…")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
