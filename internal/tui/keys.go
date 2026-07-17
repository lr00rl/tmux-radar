package tui

import "charm.land/bubbles/v2/key"

type setupKeyMap struct {
	Next     key.Binding
	Previous key.Binding
	Select   key.Binding
	Toggle   key.Binding
	Help     key.Binding
	Cancel   key.Binding
}

var setupKeys = setupKeyMap{
	Next:     key.NewBinding(key.WithKeys("tab"), key.WithHelp("tab", "next")),
	Previous: key.NewBinding(key.WithKeys("shift+tab"), key.WithHelp("shift+tab", "previous")),
	Select:   key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "select")),
	Toggle:   key.NewBinding(key.WithKeys(" "), key.WithHelp("space", "toggle")),
	Help:     key.NewBinding(key.WithKeys("?"), key.WithHelp("?", "help")),
	Cancel:   key.NewBinding(key.WithKeys("q", "ctrl+c"), key.WithHelp("q", "cancel")),
}
