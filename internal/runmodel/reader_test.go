package runmodel

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeJSONFile(t *testing.T, path string, value any) {
	t.Helper()
	payload, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(payload, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
}

func replaceJSONFile(t *testing.T, path string, value any) {
	t.Helper()
	tmp := path + ".replacement"
	writeJSONFile(t, tmp, value)
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func makeRunDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeJSONFile(t, filepath.Join(dir, "config.json"), DefaultConfig("%42", "reader goal"))
	return dir
}

func TestReaderSnapshotTracksAtomicStateReplacement(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	reader, err := Open(dir)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}

	snapshot, changed, err := reader.Snapshot()
	if err != nil {
		t.Fatalf("initial Snapshot: %v", err)
	}
	if !changed || snapshot.State != nil || snapshot.Final != nil {
		t.Fatalf("initial snapshot = %#v changed=%v", snapshot, changed)
	}
	if snapshot.Config.Goal != "reader goal" {
		t.Fatalf("config was not read: %#v", snapshot.Config)
	}

	if _, changed, err = reader.Snapshot(); err != nil || changed {
		t.Fatalf("unchanged Snapshot: changed=%v err=%v", changed, err)
	}

	statePath := filepath.Join(dir, "state.json")
	replaceJSONFile(t, statePath, State{SchemaVersion: 1, Phase: "ARMED", Status: "waiting"})
	snapshot, changed, err = reader.Snapshot()
	if err != nil || !changed || snapshot.State == nil || snapshot.State.Phase != "ARMED" {
		t.Fatalf("armed snapshot = %#v changed=%v err=%v", snapshot, changed, err)
	}
	replaceJSONFile(t, statePath, State{SchemaVersion: 1, Phase: "ARMED", Status: "waiting"})
	if _, changed, err = reader.Snapshot(); err != nil || changed {
		t.Fatalf("equivalent replacement changed derived state: changed=%v err=%v", changed, err)
	}

	replaceJSONFile(t, statePath, State{SchemaVersion: 1, Phase: "DECIDING", Status: "model call"})
	snapshot, changed, err = reader.Snapshot()
	if err != nil || !changed || snapshot.State == nil || snapshot.State.Phase != "DECIDING" {
		t.Fatalf("replaced snapshot = %#v changed=%v err=%v", snapshot, changed, err)
	}

	replaceJSONFile(t, filepath.Join(dir, "final.json"), Final{SchemaVersion: 1, Outcome: "completed", Reason: "done"})
	snapshot, changed, err = reader.Snapshot()
	if err != nil || !changed || snapshot.Final == nil || snapshot.Final.Outcome != "completed" {
		t.Fatalf("final snapshot = %#v changed=%v err=%v", snapshot, changed, err)
	}
}

func TestReaderSnapshotCommitsChangedArtifactsTransactionally(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	statePath := filepath.Join(dir, "state.json")
	finalPath := filepath.Join(dir, "final.json")
	replaceJSONFile(t, statePath, State{SchemaVersion: 1, Phase: "ARMED", Status: "waiting"})
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = reader.Snapshot(); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(statePath, []byte("{bad json}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	replaceJSONFile(t, finalPath, Final{SchemaVersion: 1, Outcome: "completed", Reason: "done"})
	if _, _, err = reader.Snapshot(); err == nil {
		t.Fatal("malformed state allowed a partial snapshot commit")
	}

	replaceJSONFile(t, statePath, State{SchemaVersion: 1, Phase: "COMPLETED", Status: "done"})
	snapshot, changed, err := reader.Snapshot()
	if err != nil || !changed || snapshot.State == nil || snapshot.Final == nil ||
		snapshot.State.Phase != "COMPLETED" || snapshot.Final.Outcome != "completed" {
		t.Fatalf("recovered snapshot = %#v changed=%v err=%v", snapshot, changed, err)
	}
}

func TestReaderSnapshotDoesNotExposeMutableCachePointers(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	configPayload, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	var config Config
	if err := json.Unmarshal(configPayload, &config); err != nil {
		t.Fatal(err)
	}
	config.Backend = validCodexBackend()
	writeJSONFile(t, filepath.Join(dir, "config.json"), config)
	writeJSONFile(t, filepath.Join(dir, "state.json"), State{
		SchemaVersion: 1, Phase: "ARMED", Status: "waiting",
		Verification: &VerificationState{PreSendFingerprint: "canonical"},
	})
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	snapshot, _, err := reader.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Config.Backend.Path = "/mutated"
	snapshot.State.Phase = "CORRUPTED"
	snapshot.State.Verification.PreSendFingerprint = "mutated"

	next, changed, err := reader.Snapshot()
	if err != nil || changed {
		t.Fatalf("unchanged canonical snapshot changed=%v err=%v", changed, err)
	}
	if next.Config.Backend.Path != "/Users/test/.local/bin/codex" || next.State.Phase != "ARMED" ||
		next.State.Verification.PreSendFingerprint != "canonical" {
		t.Fatalf("caller mutation escaped into reader cache: %#v", next)
	}
}

func TestReaderPollEventsWaitsForPartialLineAndAppendsFromOffset(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	first := `{"schema_version":1,"kind":"phase","label":"armed","future":{"ok":true}}` + "\n"
	partial := `{"schema_version":1,"kind":"model_started","label":"call`
	if err := os.WriteFile(eventsPath, []byte(first+partial), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}

	events, err := reader.PollEvents()
	if err != nil {
		t.Fatalf("first PollEvents: %v", err)
	}
	if len(events) != 1 || events[0].Kind != "phase" {
		t.Fatalf("first events = %#v", events)
	}
	if events, err = reader.PollEvents(); err != nil || len(events) != 0 {
		t.Fatalf("duplicate partial poll = %#v err=%v", events, err)
	}

	file, err := os.OpenFile(eventsPath, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.WriteString(` 1"}` + "\n" + `{"schema_version":1,"kind":"phase","label":"armed again"}` + "\n"); err != nil {
		file.Close()
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}

	events, err = reader.PollEvents()
	if err != nil {
		t.Fatalf("appended PollEvents: %v", err)
	}
	if len(events) != 2 || events[0].Kind != "model_started" || events[1].Label != "armed again" {
		t.Fatalf("appended events = %#v", events)
	}
	if events, err = reader.PollEvents(); err != nil || len(events) != 0 {
		t.Fatalf("offset replayed events = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsRecoversFromTruncation(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte(`{"schema_version":1,"kind":"old","label":"old event"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if events, err := reader.PollEvents(); err != nil || len(events) != 1 {
		t.Fatalf("initial events = %#v err=%v", events, err)
	}

	if err := os.WriteFile(eventsPath, []byte(`{"kind":"new"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "new" || events[0].SchemaVersion != 0 {
		t.Fatalf("truncated events = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsRecoversFromInodeReplacement(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte(`{"schema_version":1,"kind":"old"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err != nil {
		t.Fatal(err)
	}

	replacement := eventsPath + ".new"
	if err := os.WriteFile(replacement, []byte(`{"schema_version":1,"kind":"replacement"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, eventsPath); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "replacement" {
		t.Fatalf("replacement events = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsRecoversFromSameSizeRewrite(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	oldLine := []byte(`{"schema_version":1,"kind":"old"}` + "\n")
	newLine := []byte(`{"schema_version":1,"kind":"new"}` + "\n")
	if len(oldLine) != len(newLine) {
		t.Fatal("fixture lines must have equal length")
	}
	if err := os.WriteFile(eventsPath, oldLine, 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(eventsPath, newLine, 0o600); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(eventsPath, future, future); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "new" {
		t.Fatalf("same-size rewritten events = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsDetectsTruncateAndLargerRewrite(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte(`{"schema_version":1,"kind":"old"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err != nil {
		t.Fatal(err)
	}
	replacement := `{"schema_version":1,"kind":"new"}` + "\n" +
		`{"schema_version":1,"kind":"tail","label":"larger replacement"}` + "\n"
	if err := os.WriteFile(eventsPath, []byte(replacement), 0o600); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 2 || events[0].Kind != "new" || events[1].Kind != "tail" {
		t.Fatalf("truncate+larger rewrite events = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsPreservesCursorAcrossTemporaryDisappearance(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	first := []byte(`{"schema_version":1,"kind":"first"}` + "\n")
	if err := os.WriteFile(eventsPath, first, 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err != nil {
		t.Fatal(err)
	}
	hidden := eventsPath + ".hidden"
	if err := os.Rename(eventsPath, hidden); err != nil {
		t.Fatal(err)
	}
	if events, err := reader.PollEvents(); err != nil || len(events) != 0 {
		t.Fatalf("temporary disappearance = %#v err=%v", events, err)
	}
	if err := os.Rename(hidden, eventsPath); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(eventsPath, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"schema_version":1,"kind":"second"}` + "\n")
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "second" {
		t.Fatalf("restored journal replayed history: %#v err=%v", events, err)
	}
}

func TestReaderPollEventsContinuesAcrossReplacementWithRetainedPrefix(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	first := `{"schema_version":1,"kind":"first"}` + "\n"
	if err := os.WriteFile(eventsPath, []byte(first), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err != nil {
		t.Fatal(err)
	}
	replacement := eventsPath + ".replacement"
	if err := os.WriteFile(replacement, []byte(first+`{"schema_version":1,"kind":"second"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(replacement, eventsPath); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "second" {
		t.Fatalf("retained-prefix replacement = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsBoundsLargeJournalBatches(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	const total = 30000
	var journal bytes.Buffer
	for index := 0; index < total; index++ {
		fmt.Fprintf(&journal, `{"schema_version":1,"kind":"event","call":%d}`+"\n", index)
	}
	if journal.Len() <= maxEventPollBytes {
		t.Fatal("fixture must exceed one bounded poll")
	}
	if err := os.WriteFile(eventsPath, journal.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}

	seen := 0
	polls := 0
	for seen < total {
		events, err := reader.PollEvents()
		if err != nil {
			t.Fatalf("PollEvents batch %d: %v", polls+1, err)
		}
		if len(events) == 0 {
			t.Fatalf("PollEvents stalled after %d/%d events", seen, total)
		}
		seen += len(events)
		polls++
	}
	if seen != total || polls < 2 {
		t.Fatalf("bounded replay saw %d/%d events in %d poll(s)", seen, total, polls)
	}
}

func TestReaderPollEventsAllowsMissingOptionalJournal(t *testing.T) {
	t.Parallel()

	reader, err := Open(makeRunDir(t))
	if err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 0 {
		t.Fatalf("missing events journal = %#v err=%v", events, err)
	}
}

func TestReaderPollEventsDoesNotCommitMalformedCompleteLine(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	eventsPath := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(eventsPath, []byte("{bad json}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err == nil {
		t.Fatal("malformed complete event was accepted")
	}

	if err := os.WriteFile(eventsPath, []byte(`{"schema_version":1,"kind":"recovered"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	events, err := reader.PollEvents()
	if err != nil || len(events) != 1 || events[0].Kind != "recovered" {
		t.Fatalf("recovered events = %#v err=%v", events, err)
	}
}

func TestReaderRejectsUnsupportedArtifactVersion(t *testing.T) {
	t.Parallel()

	dir := makeRunDir(t)
	writeJSONFile(t, filepath.Join(dir, "state.json"), map[string]any{"schema_version": 2, "phase": "ARMED"})
	reader, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = reader.Snapshot(); err == nil {
		t.Fatal("unsupported state schema was accepted")
	}

	if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), []byte(`{"schema_version":2,"kind":"future"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err = reader.PollEvents(); err == nil {
		t.Fatal("unsupported event schema was accepted")
	}
}
