package tui

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/lr00rl/tmux-radar/internal/runmodel"
)

const ownerHeartbeatInterval = time.Second

// OwnerLease ties an engine run to this TUI process without spawning a waiter.
type OwnerLease struct {
	descriptor runmodel.OwnerDescriptor
	interval   time.Duration
	stop       chan struct{}
	done       chan struct{}
	closeOnce  sync.Once
	closeErr   error
}

func StartOwnerLease(stateRoot string, surface Surface, monitorPane string) (*OwnerLease, error) {
	return startOwnerLease(stateRoot, surface, monitorPane, ownerHeartbeatInterval)
}

func startOwnerLease(stateRoot string, surface Surface, monitorPane string, interval time.Duration) (*OwnerLease, error) {
	if !filepath.IsAbs(stateRoot) {
		return nil, errors.New("owner lease: state root must be absolute")
	}
	if interval <= 0 {
		return nil, errors.New("owner lease: heartbeat interval must be positive")
	}
	kind := runmodel.OwnerKind(surface)
	switch kind {
	case runmodel.OwnerSplit:
		if monitorPane == "" {
			return nil, errors.New("owner lease: split surface requires a monitor pane")
		}
	case runmodel.OwnerPopup:
		monitorPane = ""
	default:
		return nil, fmt.Errorf("owner lease: unsupported surface %q", surface)
	}

	tokenBytes := make([]byte, 16)
	if _, err := rand.Read(tokenBytes); err != nil {
		return nil, fmt.Errorf("owner lease: generate token: %w", err)
	}
	token := hex.EncodeToString(tokenBytes)
	directory := filepath.Join(stateRoot, "ai-owners")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return nil, fmt.Errorf("owner lease: create heartbeat directory: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return nil, fmt.Errorf("owner lease: secure heartbeat directory: %w", err)
	}

	descriptor := runmodel.OwnerDescriptor{
		SchemaVersion: runmodel.CurrentSchemaVersion,
		Kind:          kind,
		Pane:          monitorPane,
		PID:           os.Getpid(),
		Token:         token,
		HeartbeatPath: filepath.Join(directory, fmt.Sprintf("%d-%s.heartbeat", os.Getpid(), token)),
	}
	lease := &OwnerLease{
		descriptor: descriptor,
		interval:   interval,
		stop:       make(chan struct{}),
		done:       make(chan struct{}),
	}
	if err := lease.refresh(); err != nil {
		return nil, err
	}
	go lease.run()
	return lease, nil
}

func (lease *OwnerLease) Descriptor() runmodel.OwnerDescriptor {
	return lease.descriptor
}

func (lease *OwnerLease) run() {
	defer close(lease.done)
	ticker := time.NewTicker(lease.interval)
	defer ticker.Stop()
	for {
		select {
		case <-lease.stop:
			return
		case <-ticker.C:
			// A failed refresh intentionally leaves the previous timestamp in place;
			// the engine's bounded lease check then stops the watcher safely.
			_ = lease.refresh()
		}
	}
}

func (lease *OwnerLease) refresh() error {
	payload := fmt.Sprintf(
		"schema_version=%d\ntoken=%s\npid=%d\nupdated_epoch=%d\n",
		runmodel.CurrentSchemaVersion,
		lease.descriptor.Token,
		lease.descriptor.PID,
		time.Now().Unix(),
	)
	if err := writeOwnerHeartbeat(lease.descriptor.HeartbeatPath, []byte(payload)); err != nil {
		return fmt.Errorf("owner lease: refresh heartbeat: %w", err)
	}
	return nil
}

func writeOwnerHeartbeat(path string, payload []byte) error {
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, ".heartbeat-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	removeTemporary := true
	defer func() {
		if removeTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()

	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(payload); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	removeTemporary = false
	return nil
}

func (lease *OwnerLease) Close() error {
	if lease == nil {
		return nil
	}
	lease.closeOnce.Do(func() {
		close(lease.stop)
		<-lease.done
		if err := os.Remove(lease.descriptor.HeartbeatPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			lease.closeErr = fmt.Errorf("owner lease: remove heartbeat: %w", err)
		}
	})
	return lease.closeErr
}
