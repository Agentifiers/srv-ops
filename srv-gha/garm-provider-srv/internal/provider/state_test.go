package provider

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

func testRecord(name, pool string) Record {
	return Record{
		Name:         name,
		ProviderID:   ProviderID(name),
		PoolID:       pool,
		ControllerID: "ctrl",
		CreatedAt:    time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC),
	}
}

func TestStoreCRUD(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s := NewStore(dir)

	if recs, err := s.List(); err != nil || len(recs) != 0 {
		t.Fatalf("List on missing dir = %v, %v", recs, err)
	}
	if _, err := s.Get(ProviderID("nope")); !errors.Is(err, errRecordNotFound) {
		t.Fatalf("Get missing = %v", err)
	}

	a, b := testRecord("garm-A", "pool1"), testRecord("garm-B", "pool2")
	for _, r := range []Record{a, b} {
		l, err := s.Lock(context.Background(), r.ProviderID)
		if err != nil {
			t.Fatal(err)
		}
		if err := s.Put(r); err != nil {
			t.Fatal(err)
		}
		l.Unlock()
	}
	fi, err := os.Stat(dir)
	if err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("state dir mode = %v, %v", fi.Mode(), err)
	}
	got, err := s.Get(a.ProviderID)
	if err != nil || got != a {
		t.Fatalf("Get = %+v, %v; want %+v", got, err, a)
	}
	// Unrelated files and temp files are ignored by List.
	os.WriteFile(filepath.Join(dir, "."+a.ProviderID+".json.tmp-1"), []byte("{"), 0o600)
	os.WriteFile(filepath.Join(dir, "notes.json"), []byte("{"), 0o600)
	recs, err := s.List()
	if err != nil || len(recs) != 2 {
		t.Fatalf("List = %v, %v", recs, err)
	}

	if err := s.Delete(a.ProviderID); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(a.ProviderID); err != nil {
		t.Fatalf("second Delete = %v", err)
	}
	if _, err := s.Get(a.ProviderID); !errors.Is(err, errRecordNotFound) {
		t.Fatalf("Get after Delete = %v", err)
	}
}

func TestStoreTryLockExclusive(t *testing.T) {
	s := NewStore(t.TempDir())
	id := ProviderID("x")
	l, ok, err := s.TryLock(id)
	if err != nil || !ok {
		t.Fatalf("TryLock = %v, %v", ok, err)
	}
	if _, ok, err := s.TryLock(id); err != nil || ok {
		t.Fatalf("second TryLock = %v, %v; want busy", ok, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := s.Lock(ctx, id); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Lock while held = %v", err)
	}
	l.Unlock()
	l2, ok, err := s.TryLock(id)
	if err != nil || !ok {
		t.Fatalf("TryLock after Unlock = %v, %v", ok, err)
	}
	l2.UnlockAndRemove()
	if _, err := os.Stat(s.lockPath(id)); !os.IsNotExist(err) {
		t.Fatalf("lock file still present: %v", err)
	}
}

// A waiter that opened the lock file before the holder unlinked it must not
// end up "holding" the orphaned inode.
func TestStoreLockSurvivesRemoval(t *testing.T) {
	s := NewStore(t.TempDir())
	id := ProviderID("x")
	l, err := s.Lock(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan *Lock)
	go func() {
		l2, err := s.Lock(context.Background(), id)
		if err != nil {
			t.Error(err)
		}
		got <- l2
	}()
	time.Sleep(250 * time.Millisecond)
	l.UnlockAndRemove()
	l2 := <-got
	held, err1 := l2.f.Stat()
	cur, err2 := os.Stat(s.lockPath(id))
	if err1 != nil || err2 != nil || !os.SameFile(held, cur) {
		t.Fatalf("waiter holds a lock not at the lock path: %v %v", err1, err2)
	}
	if _, ok, _ := s.TryLock(id); ok {
		t.Fatal("lock not exclusive after removal")
	}
	l2.Unlock()
}

// Concurrent read-modify-write cycles under the instance lock lose nothing.
func TestStoreConcurrentUpdates(t *testing.T) {
	s := NewStore(t.TempDir())
	rec := testRecord("garm-C", "pool")
	rec.Flavor = "0"
	l, _ := s.Lock(context.Background(), rec.ProviderID)
	if err := s.Put(rec); err != nil {
		t.Fatal(err)
	}
	l.Unlock()

	const n = 32
	var wg sync.WaitGroup
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			l, err := s.Lock(context.Background(), rec.ProviderID)
			if err != nil {
				t.Error(err)
				return
			}
			defer l.Unlock()
			r, err := s.Get(rec.ProviderID)
			if err != nil {
				t.Error(err)
				return
			}
			v, _ := strconv.Atoi(r.Flavor)
			r.Flavor = strconv.Itoa(v + 1)
			if err := s.Put(r); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	r, err := s.Get(rec.ProviderID)
	if err != nil || r.Flavor != strconv.Itoa(n) {
		t.Fatalf("counter = %q, %v; want %d", r.Flavor, err, n)
	}
	entries, _ := os.ReadDir(s.dir)
	for _, e := range entries {
		if filepath.Ext(e.Name()) != ".json" && filepath.Ext(e.Name()) != ".lock" {
			t.Errorf("leftover file %s", e.Name())
		}
	}
}
