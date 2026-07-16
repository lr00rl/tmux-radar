package runmodel

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sync"
)

const (
	maxEventPollBytes        = 1 << 20
	eventTailFingerprintSize = 4 << 10
)

type Snapshot struct {
	Config Config
	State  *State
	Final  *Final
}

type Reader struct {
	snapshotMu sync.Mutex
	eventsMu   sync.Mutex

	runDir string

	snapshot      Snapshot
	snapshotReady bool
	stateInfo     os.FileInfo
	finalInfo     os.FileInfo

	eventsOffset     int64
	eventsTailOffset int64
	eventsTail       []byte
}

func Open(runDir string) (*Reader, error) {
	info, err := os.Stat(runDir)
	if err != nil {
		return nil, fmt.Errorf("open run directory: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("open run directory: %s is not a directory", runDir)
	}

	payload, err := os.ReadFile(filepath.Join(runDir, "config.json"))
	if err != nil {
		return nil, fmt.Errorf("read config.json: %w", err)
	}
	config, err := DecodeConfig(payload)
	if err != nil {
		return nil, fmt.Errorf("decode config.json: %w", err)
	}

	return &Reader{
		runDir:   filepath.Clean(runDir),
		snapshot: Snapshot{Config: config},
	}, nil
}

func (reader *Reader) Snapshot() (Snapshot, bool, error) {
	reader.snapshotMu.Lock()
	defer reader.snapshotMu.Unlock()

	candidate := reader.snapshot
	stateInfo := reader.stateInfo
	finalInfo := reader.finalInfo

	state, nextStateInfo, fileChanged, err := readOptionalJSON[State](
		filepath.Join(reader.runDir, "state.json"), reader.stateInfo,
	)
	if err != nil {
		return Snapshot{}, false, err
	}
	if fileChanged {
		candidate.State = state
		stateInfo = nextStateInfo
	}

	final, nextFinalInfo, fileChanged, err := readOptionalJSON[Final](
		filepath.Join(reader.runDir, "final.json"), reader.finalInfo,
	)
	if err != nil {
		return Snapshot{}, false, err
	}
	if fileChanged {
		candidate.Final = final
		finalInfo = nextFinalInfo
	}

	changed := !reader.snapshotReady || !reflect.DeepEqual(reader.snapshot, candidate)
	reader.snapshot = candidate
	reader.snapshotReady = true
	reader.stateInfo = stateInfo
	reader.finalInfo = finalInfo
	return cloneSnapshot(candidate), changed, nil
}

func cloneSnapshot(snapshot Snapshot) Snapshot {
	cloned := snapshot
	if snapshot.Config.Backend != nil {
		backend := *snapshot.Config.Backend
		cloned.Config.Backend = &backend
	}
	if snapshot.State != nil {
		state := *snapshot.State
		if snapshot.State.Verification != nil {
			verification := *snapshot.State.Verification
			state.Verification = &verification
		}
		cloned.State = &state
	}
	if snapshot.Final != nil {
		final := *snapshot.Final
		cloned.Final = &final
	}
	return cloned
}

func readOptionalJSON[T any](path string, previousInfo os.FileInfo) (*T, os.FileInfo, bool, error) {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, previousInfo != nil, nil
	}
	if err != nil {
		return nil, previousInfo, false, fmt.Errorf("stat %s: %w", filepath.Base(path), err)
	}
	if sameArtifact(previousInfo, info) {
		return nil, previousInfo, false, nil
	}

	payload, err := os.ReadFile(path)
	if err != nil {
		return nil, previousInfo, false, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	var value T
	if err := json.Unmarshal(payload, &value); err != nil {
		return nil, previousInfo, false, fmt.Errorf("decode %s: %w", filepath.Base(path), err)
	}
	if versioned, ok := any(&value).(interface{ schemaVersion() int }); ok {
		if err := ValidateSchemaVersion(versioned.schemaVersion()); err != nil {
			return nil, previousInfo, false, fmt.Errorf("decode %s: %w", filepath.Base(path), err)
		}
	}
	return &value, info, true, nil
}

func (state *State) schemaVersion() int { return state.SchemaVersion }
func (final *Final) schemaVersion() int { return final.SchemaVersion }

func sameArtifact(previous, current os.FileInfo) bool {
	if previous == nil || current == nil {
		return previous == nil && current == nil
	}
	return os.SameFile(previous, current) &&
		previous.Size() == current.Size() &&
		previous.ModTime().Equal(current.ModTime())
}

func (reader *Reader) PollEvents() ([]Event, error) {
	reader.eventsMu.Lock()
	defer reader.eventsMu.Unlock()

	path := filepath.Join(reader.runDir, "events.jsonl")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("open events.jsonl: %w", err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat events.jsonl: %w", err)
	}
	start := reader.eventsOffset
	prefixMatches, err := committedEventTailMatches(
		file, info.Size(), reader.eventsOffset, reader.eventsTailOffset, reader.eventsTail,
	)
	if err != nil {
		return nil, fmt.Errorf("verify events.jsonl cursor: %w", err)
	}
	if !prefixMatches {
		start = 0
	}
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return nil, fmt.Errorf("seek events.jsonl: %w", err)
	}
	payload, err := io.ReadAll(io.LimitReader(file, maxEventPollBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read events.jsonl: %w", err)
	}
	batch := payload
	if len(batch) > maxEventPollBytes {
		batch = batch[:maxEventPollBytes]
	}

	lastNewline := bytes.LastIndexByte(batch, '\n')
	if lastNewline < 0 {
		if len(payload) > maxEventPollBytes {
			return nil, fmt.Errorf("events.jsonl line exceeds %d bytes at offset %d", maxEventPollBytes, start)
		}
		return nil, nil
	}

	complete := batch[:lastNewline+1]
	lines := bytes.Split(complete, []byte{'\n'})
	events := make([]Event, 0, len(lines)-1)
	for lineNumber, line := range lines {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		var event Event
		if err := json.Unmarshal(line, &event); err != nil {
			return nil, fmt.Errorf("decode events.jsonl line at offset %d (%d): %w", start, lineNumber+1, err)
		}
		if err := ValidateSchemaVersion(event.SchemaVersion); err != nil {
			return nil, fmt.Errorf("decode events.jsonl line at offset %d (%d): %w", start, lineNumber+1, err)
		}
		events = append(events, event)
	}

	nextOffset := start + int64(lastNewline+1)
	tailOffset, tail, err := readCommittedEventTail(file, nextOffset)
	if err != nil {
		return nil, fmt.Errorf("read events.jsonl cursor fingerprint: %w", err)
	}
	reader.eventsOffset = nextOffset
	reader.eventsTailOffset = tailOffset
	reader.eventsTail = tail
	return events, nil
}

func committedEventTailMatches(file *os.File, size, offset, tailOffset int64, tail []byte) (bool, error) {
	if offset == 0 {
		return true, nil
	}
	if size < offset || len(tail) == 0 {
		return false, nil
	}
	current := make([]byte, len(tail))
	if _, err := file.ReadAt(current, tailOffset); err != nil {
		return false, err
	}
	return bytes.Equal(current, tail), nil
}

func readCommittedEventTail(file *os.File, offset int64) (int64, []byte, error) {
	tailOffset := offset - eventTailFingerprintSize
	if tailOffset < 0 {
		tailOffset = 0
	}
	tail := make([]byte, offset-tailOffset)
	if len(tail) == 0 {
		return tailOffset, nil, nil
	}
	if _, err := file.ReadAt(tail, tailOffset); err != nil {
		return 0, nil, err
	}
	return tailOffset, tail, nil
}
