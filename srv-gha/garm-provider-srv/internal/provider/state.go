package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Record is the per-instance metadata srv cannot hold for us.
type Record struct {
	Name         string    `json:"name"`
	ProviderID   string    `json:"provider_id"`
	PoolID       string    `json:"pool_id"`
	ControllerID string    `json:"controller_id"`
	Image        string    `json:"image,omitempty"`
	Flavor       string    `json:"flavor,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
}

var errRecordNotFound = errors.New("state record not found")

// Store keeps one <provider_id>.json record per instance in a directory.
// Every mutation of a record happens while holding that instance's lock
// (<provider_id>.lock, flock), and records are replaced atomically by rename,
// so concurrent provider processes never observe partial writes.
type Store struct {
	dir string
}

// NewStore returns a store rooted at dir. The directory is created (0700) on
// first write, so read-only commands work before it exists.
func NewStore(dir string) *Store {
	return &Store{dir: dir}
}

func (s *Store) ensureDir() error {
	if err := os.MkdirAll(s.dir, 0o700); err != nil {
		return fmt.Errorf("creating state dir: %w", err)
	}
	return nil
}

func (s *Store) recordPath(id string) string { return filepath.Join(s.dir, id+".json") }
func (s *Store) lockPath(id string) string   { return filepath.Join(s.dir, id+".lock") }

// Lock is a held exclusive flock on one instance.
type Lock struct {
	f    *os.File
	path string
}

const lockPollInterval = 100 * time.Millisecond

// Lock blocks until the instance lock is held or ctx is done.
func (s *Store) Lock(ctx context.Context, id string) (*Lock, error) {
	for {
		l, ok, err := s.TryLock(id)
		if err != nil || ok {
			return l, err
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("waiting for lock on %s: %w", id, ctx.Err())
		case <-time.After(lockPollInterval):
		}
	}
}

// TryLock takes the instance lock without blocking; ok is false if another
// process holds it.
func (s *Store) TryLock(id string) (l *Lock, ok bool, err error) {
	if err := s.ensureDir(); err != nil {
		return nil, false, err
	}
	path := s.lockPath(id)
	for {
		f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
		if err != nil {
			return nil, false, fmt.Errorf("opening lock file: %w", err)
		}
		if err := flock(f, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			f.Close()
			if errors.Is(err, syscall.EWOULDBLOCK) {
				return nil, false, nil
			}
			return nil, false, fmt.Errorf("locking %s: %w", path, err)
		}
		// The holder may have unlinked the lock file before we locked our
		// descriptor; only a lock on the inode currently at path counts.
		held, err1 := f.Stat()
		cur, err2 := os.Stat(path)
		if err1 == nil && err2 == nil && os.SameFile(held, cur) {
			return &Lock{f: f, path: path}, true, nil
		}
		f.Close()
		if err1 != nil {
			return nil, false, fmt.Errorf("stat lock file: %w", err1)
		}
		if err2 != nil && !errors.Is(err2, fs.ErrNotExist) {
			return nil, false, fmt.Errorf("stat lock file: %w", err2)
		}
	}
}

// Unlock releases the lock and keeps the lock file.
func (l *Lock) Unlock() {
	l.f.Close()
}

// UnlockAndRemove deletes the lock file while still holding it, then
// releases it. Use once the instance is gone for good.
func (l *Lock) UnlockAndRemove() {
	os.Remove(l.path)
	l.f.Close()
}

func flock(f *os.File, how int) error {
	for {
		err := syscall.Flock(int(f.Fd()), how)
		if err != syscall.EINTR {
			return err
		}
	}
}

// Put atomically writes rec. The caller must hold rec's instance lock.
func (s *Store) Put(rec Record) error {
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.dir, "."+rec.ProviderID+".json.tmp-*")
	if err != nil {
		return fmt.Errorf("writing state record: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return fmt.Errorf("writing state record: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("syncing state record: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("writing state record: %w", err)
	}
	if err := os.Rename(tmp.Name(), s.recordPath(rec.ProviderID)); err != nil {
		return fmt.Errorf("installing state record: %w", err)
	}
	return nil
}

// Get returns the record for id, or errRecordNotFound.
func (s *Store) Get(id string) (Record, error) {
	data, err := os.ReadFile(s.recordPath(id))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Record{}, errRecordNotFound
		}
		return Record{}, fmt.Errorf("reading state record: %w", err)
	}
	var rec Record
	if err := json.Unmarshal(data, &rec); err != nil {
		return Record{}, fmt.Errorf("decoding state record %s: %w", id, err)
	}
	return rec, nil
}

// Delete removes the record for id; a missing record is not an error. The
// caller must hold the instance lock.
func (s *Store) Delete(id string) error {
	if err := os.Remove(s.recordPath(id)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("removing state record: %w", err)
	}
	return nil
}

// List returns all records. Records removed concurrently are skipped.
func (s *Store) List() ([]Record, error) {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading state dir: %w", err)
	}
	var recs []Record
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || !IsProviderID(id) {
			continue
		}
		rec, err := s.Get(id)
		if errors.Is(err, errRecordNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		recs = append(recs, rec)
	}
	return recs, nil
}
