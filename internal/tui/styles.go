package tui

import "charm.land/lipgloss/v2"

type semanticStyles struct {
	title      lipgloss.Style
	phase      lipgloss.Style
	muted      lipgloss.Style
	focus      lipgloss.Style
	focused    lipgloss.Style
	group      lipgloss.Style
	provenance lipgloss.Style
	start      lipgloss.Style
	success    lipgloss.Style
	warning    lipgloss.Style
	danger     lipgloss.Style
}

var setupStyles = semanticStyles{
	title:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("81")),
	phase:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("229")),
	muted:      lipgloss.NewStyle().Foreground(lipgloss.Color("245")),
	focus:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("81")),
	focused:    lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("255")),
	group:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("117")),
	provenance: lipgloss.NewStyle().Foreground(lipgloss.Color("244")),
	start:      lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("120")),
	success:    lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("120")),
	warning:    lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("221")),
	danger:     lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("203")),
}
