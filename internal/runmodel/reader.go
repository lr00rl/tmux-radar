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

type Snapshot struct {
	Config Config
	State  *State
	Final  *Final
}

type Reader struct {
	mu sync.Mutex

	runDir string

	snapshot      Snapshot
	snapshotReady bool
	stateInfo     os.FileInfo
	finalInfo     os.FileInfo

	eventsInfo   os.FileInfo
	eventsOffset int64
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
	reader.mu.Lock()
	defer reader.mu.Unlock()

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
	return candidate, changed, nil
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
	reader.mu.Lock()
	defer reader.mu.Unlock()

	path := filepath.Join(reader.runDir, "events.jsonl")
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		reader.eventsInfo = nil
		reader.eventsOffset = 0
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
	if reader.eventsInfo != nil {
		if !os.SameFile(reader.eventsInfo, info) || info.Size() < start ||
			(info.Size() == reader.eventsInfo.Size() && !info.ModTime().Equal(reader.eventsInfo.ModTime())) {
			start = 0
		}
	}
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return nil, fmt.Errorf("seek events.jsonl: %w", err)
	}
	payload, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("read events.jsonl: %w", err)
	}
	finalInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("restat events.jsonl: %w", err)
	}

	lastNewline := bytes.LastIndexByte(payload, '\n')
	if lastNewline < 0 {
		reader.eventsInfo = finalInfo
		if start == 0 {
			reader.eventsOffset = 0
		}
		return nil, nil
	}

	complete := payload[:lastNewline+1]
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

	reader.eventsInfo = finalInfo
	reader.eventsOffset = start + int64(lastNewline+1)
	return events, nil
}
