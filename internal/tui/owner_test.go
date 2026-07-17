package tui

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

func TestOwnerLeaseWritesFirstHeartbeatBeforeReturning(t *testing.T) {
	lease, err := startOwnerLease(t.TempDir(), SurfaceSplit, "%42", 20*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lease.Close() })

	descriptor := lease.Descriptor()
	if descriptor.Kind != runmodel.OwnerSplit || descriptor.Pane != "%42" {
		t.Fatalf("descriptor = %#v", descriptor)
	}
	if descriptor.PID != os.Getpid() || len(descriptor.Token) != 32 || !filepath.IsAbs(descriptor.HeartbeatPath) {
		t.Fatalf("invalid active owner descriptor: %#v", descriptor)
	}
	assertHeartbeat(t, descriptor.HeartbeatPath, descriptor.Token, descriptor.PID)
}

func TestOwnerLeasePopupOmitsPaneAndRefreshesInProcess(t *testing.T) {
	lease, err := startOwnerLease(t.TempDir(), SurfacePopup, "%ignored", 20*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = lease.Close() })

	descriptor := lease.Descriptor()
	if descriptor.Kind != runmodel.OwnerPopup || descriptor.Pane != "" {
		t.Fatalf("popup descriptor = %#v", descriptor)
	}
	before, err := os.Stat(descriptor.HeartbeatPath)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(70 * time.Millisecond)
	after, err := os.Stat(descriptor.HeartbeatPath)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().After(before.ModTime()) {
		t.Fatalf("heartbeat was not refreshed: before=%s after=%s", before.ModTime(), after.ModTime())
	}
	assertHeartbeat(t, descriptor.HeartbeatPath, descriptor.Token, descriptor.PID)
}

func TestOwnerLeaseCloseRemovesHeartbeatAndStopsRefresh(t *testing.T) {
	lease, err := startOwnerLease(t.TempDir(), SurfaceSplit, "%9", 15*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	path := lease.Descriptor().HeartbeatPath
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lease.Close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("heartbeat after close: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("heartbeat recreated after close: %v", err)
	}
}

func TestOwnerLeaseRejectsInvalidInputsWithoutArtifacts(t *testing.T) {
	root := t.TempDir()
	for _, test := range []struct {
		name    string
		root    string
		surface Surface
		pane    string
	}{
		{name: "relative root", root: "relative", surface: SurfaceSplit, pane: "%1"},
		{name: "missing split pane", root: root, surface: SurfaceSplit},
		{name: "unsupported surface", root: root, surface: Surface("other"), pane: "%1"},
	} {
		t.Run(test.name, func(t *testing.T) {
			lease, err := startOwnerLease(test.root, test.surface, test.pane, time.Second)
			if err == nil || lease != nil {
				t.Fatalf("lease=%v err=%v", lease, err)
			}
		})
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("invalid inputs created artifacts: %v", entries)
	}
}

func assertHeartbeat(t *testing.T, path, token string, pid int) {
	t.Helper()
	payload, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	values := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(payload)), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			t.Fatalf("malformed heartbeat line %q", line)
		}
		values[key] = value
	}
	if values["schema_version"] != "1" || values["token"] != token || values["pid"] != strconv.Itoa(pid) {
		t.Fatalf("heartbeat values = %#v", values)
	}
	updated, err := strconv.ParseInt(values["updated_epoch"], 10, 64)
	if err != nil || updated <= 0 {
		t.Fatalf("updated_epoch=%q err=%v", values["updated_epoch"], err)
	}
}
