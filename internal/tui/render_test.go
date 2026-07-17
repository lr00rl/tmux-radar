package tui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

func stripANSI(value string) string   { return ansi.Strip(value) }
func printableWidth(value string) int { return ansi.StringWidth(value) }

func TestSetupRenderingFitsFixedTerminalSizes(t *testing.T) {
	for _, size := range []struct{ width, height int }{{40, 18}, {56, 24}, {84, 40}, {96, 50}} {
		t.Run(fmt.Sprintf("%dx%d", size.width, size.height), func(t *testing.T) {
			model := readySetup(EntryAdvanced)
			model = updateSetup(t, model, tea.WindowSizeMsg{Width: size.width, Height: size.height})
			view := ansi.Strip(model.View())
			lines := strings.Split(strings.TrimSuffix(view, "\n"), "\n")
			if len(lines) > size.height {
				t.Fatalf("rendered %d rows into height %d\n%s", len(lines), size.height, view)
			}
			for index, line := range lines {
				if got := printableWidth(line); got > size.width {
					t.Fatalf("line %d width=%d > %d: %q", index+1, got, size.width, line)
				}
			}
			if !strings.Contains(view, "SETUP") || !strings.Contains(view, "gpt-5.6-luna") {
				t.Fatalf("essential setup context missing at %dx%d\n%s", size.width, size.height, view)
			}
		})
	}
}

func TestSetupStartAndEveryAdvancedFieldRemainReachable(t *testing.T) {
	model := readySetup(EntryAdvanced)
	model = updateSetup(t, model, tea.WindowSizeMsg{Width: 40, Height: 18})
	for _, spec := range advancedFields {
		model.setFocus(spec.ID)
		view := stripANSI(model.View())
		if !strings.Contains(view, spec.Label) {
			t.Fatalf("focused advanced field %q is outside the viewport\n%s", spec.ID, view)
		}
	}
	model.setFocus(fieldStart)
	view := stripANSI(model.View())
	if !strings.Contains(view, "Start supervision") {
		t.Fatalf("Start is not reachable in narrow rendering\n%s", view)
	}
}
