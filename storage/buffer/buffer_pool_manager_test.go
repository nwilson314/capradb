package buffer

import (
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"capradb/storage/disk"
)

// helper to set up a BPM for tests
func setupBPM(t *testing.T, poolSize uint32) (*BufferPoolManager, func()) {
	tmpFile, err := os.CreateTemp("", "bpm_test_*.db")
	if err != nil {
		t.Fatalf("failed to create temp file: %v", err)
	}
	tmpFile.Close()

	dm, err := disk.NewDiskManager(tmpFile.Name())
	if err != nil {
		os.Remove(tmpFile.Name())
		t.Fatalf("failed to create disk manager: %v", err)
	}

	scheduler := disk.NewDiskScheduler(dm)
	bpm := NewBufferPoolManager(poolSize, dm, scheduler)

	cleanup := func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}

	return bpm, cleanup
}

func TestNewBufferPoolManager(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	if bpm == nil {
		t.Fatal("expected non-nil BufferPoolManager")
	}
}

func TestNewPage(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	// Allocate a new page
	guard, err := bpm.NewPage()
	if err != nil {
		t.Fatalf("NewPage failed: %v", err)
	}

	pageID := guard.page.ID

	// First page should have ID 0
	if pageID != 0 {
		t.Errorf("expected pageID 0, got %d", pageID)
	}

	// Page should be pinned with count 1
	pinCount, _ := bpm.GetPinCount(pageID)
	if pinCount != 1 {
		t.Errorf("expected pin count 1, got %d", pinCount)
	}

	// Should have used one frame from the free list
	if len(bpm.emptyFrames) != 9 {
		t.Errorf("expected 9 free frames, got %d", len(bpm.emptyFrames))
	}

	guard.Drop()
}

func TestReadPageInMemory(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	// Create a page first
	newGuard, _ := bpm.NewPage()
	pageID := newGuard.page.ID
	newGuard.Drop()

	// Read the same page - should come from memory, not disk
	readGuard, err := bpm.ReadPage(pageID)
	if err != nil {
		t.Fatalf("ReadPage failed: %v", err)
	}

	if readGuard.page == nil {
		t.Fatal("expected non-nil page")
	}

	if readGuard.page.ID != pageID {
		t.Errorf("expected page ID %d, got %d", pageID, readGuard.page.ID)
	}

	// Pin count should be 1 (ReadPage)
	pinCount, _ := bpm.GetPinCount(pageID)
	if pinCount != 1 {
		t.Errorf("expected pin count 1, got %d", pinCount)
	}

	readGuard.Drop()
}

func TestWritePageInMemory(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	// Create a page first
	newGuard, _ := bpm.NewPage()
	pageID := newGuard.page.ID
	newGuard.Drop()

	// Write to the same page
	writeGuard, err := bpm.WritePage(pageID)
	if err != nil {
		t.Fatalf("WritePage failed: %v", err)
	}

	writeGuard.page.InsertRecord([]byte("test data"))
	writeGuard.Drop()

	// Verify dirty flag is set
	frameID := bpm.pageToFrame[pageID]
	if !bpm.frameHeaders[frameID].dirty {
		t.Error("expected frame to be marked dirty after WritePage.Drop()")
	}
}

func TestGuardDrop(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	guard, _ := bpm.NewPage()
	pageID := guard.page.ID

	// Pin count starts at 1
	pinCount, _ := bpm.GetPinCount(pageID)
	if pinCount != 1 {
		t.Errorf("expected pin count 1, got %d", pinCount)
	}

	// Drop the guard
	guard.Drop()

	// Pin count should now be 0
	pinCount, _ = bpm.GetPinCount(pageID)
	if pinCount != 0 {
		t.Errorf("expected pin count 0, got %d", pinCount)
	}
}

func TestEviction(t *testing.T) {
	// Small pool to force eviction
	bpm, cleanup := setupBPM(t, 3)
	defer cleanup()

	// Fill up the buffer pool
	guard0, _ := bpm.NewPage()
	page0 := guard0.page.ID
	guard0.page.InsertRecord([]byte("hello from page 0"))
	guard0.Drop()

	guard1, _ := bpm.NewPage()
	page1 := guard1.page.ID
	guard1.Drop()

	guard2, _ := bpm.NewPage()
	page2 := guard2.page.ID
	guard2.Drop()

	// Verify all have pin count 0
	for _, pid := range []uint32{page0, page1, page2} {
		pc, _ := bpm.GetPinCount(pid)
		if pc != 0 {
			t.Errorf("expected pin count 0 for page %d, got %d", pid, pc)
		}
	}

	// Now create a new page - this MUST evict something
	guard3, err := bpm.NewPage()
	if err != nil {
		t.Fatalf("NewPage failed after eviction should have worked: %v", err)
	}
	page3 := guard3.page.ID

	// We should have 3 pages in memory, one was evicted
	if len(bpm.pageToFrame) != 3 {
		t.Errorf("expected 3 pages in memory, got %d", len(bpm.pageToFrame))
	}

	// page3 should definitely be in memory
	if _, ok := bpm.pageToFrame[page3]; !ok {
		t.Error("page3 should be in memory")
	}

	guard3.Drop()

	// Now read page0 - it should come from disk (was evicted and dirty)
	readGuard, err := bpm.ReadPage(page0)
	if err != nil {
		t.Fatalf("ReadPage(page0) failed: %v", err)
	}

	// Verify the data we wrote persisted
	record, err := readGuard.page.GetRecord(0)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}

	if string(record) != "hello from page 0" {
		t.Errorf("expected 'hello from page 0', got '%s'", string(record))
	}

	readGuard.Drop()
}

func TestFlushPage(t *testing.T) {
	bpm, cleanup := setupBPM(t, 3)
	defer cleanup()

	// Create a page and write data
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.page.InsertRecord([]byte("flush me"))
	guard.Drop()

	// Verify it's dirty
	frameID := bpm.pageToFrame[pageID]
	if !bpm.frameHeaders[frameID].dirty {
		t.Fatal("page should be dirty before flush")
	}

	// Flush the page
	ok := bpm.FlushPage(pageID)
	if !ok {
		t.Fatal("FlushPage returned false")
	}

	// After flush, dirty flag should be cleared
	if bpm.frameHeaders[frameID].dirty {
		t.Error("page should not be dirty after flush")
	}

	// Page should still be in memory
	if _, ok := bpm.pageToFrame[pageID]; !ok {
		t.Error("page should still be in memory after flush")
	}
}

func TestFlushAllPages(t *testing.T) {
	bpm, cleanup := setupBPM(t, 5)
	defer cleanup()

	// Create multiple pages with data
	var pages []uint32
	for i := 0; i < 3; i++ {
		guard, _ := bpm.NewPage()
		pages = append(pages, guard.page.ID)
		guard.page.InsertRecord([]byte("data"))
		guard.Drop()
	}

	// Verify all are dirty
	for _, pid := range pages {
		frameID := bpm.pageToFrame[pid]
		if !bpm.frameHeaders[frameID].dirty {
			t.Errorf("page %d should be dirty before flush", pid)
		}
	}

	// Flush all
	bpm.FlushAllPages()

	// Verify all are clean
	for _, pid := range pages {
		frameID := bpm.pageToFrame[pid]
		if bpm.frameHeaders[frameID].dirty {
			t.Errorf("page %d should not be dirty after FlushAllPages", pid)
		}
	}
}

func TestDeletePage(t *testing.T) {
	bpm, cleanup := setupBPM(t, 5)
	defer cleanup()

	guard, _ := bpm.NewPage()
	pageID := guard.page.ID

	// Can't delete a pinned page
	ok := bpm.DeletePage(pageID)
	if ok {
		t.Error("should not be able to delete pinned page")
	}

	// Drop the guard (unpin)
	guard.Drop()

	// Now delete should work
	ok = bpm.DeletePage(pageID)
	if !ok {
		t.Error("DeletePage should succeed on unpinned page")
	}

	// Page should no longer be in memory
	if _, ok := bpm.pageToFrame[pageID]; ok {
		t.Error("deleted page should not be in pageToFrame")
	}

	// Pin count should error (page doesn't exist)
	_, err := bpm.GetPinCount(pageID)
	if err == nil {
		t.Error("GetPinCount should error for deleted page")
	}

	// Frame should be back on free list
	if len(bpm.emptyFrames) != 5 {
		t.Errorf("expected 5 free frames after delete, got %d", len(bpm.emptyFrames))
	}
}

func TestDeadlock(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	// Create two pages
	guard0, _ := bpm.NewPage()
	page0 := guard0.page.ID

	guard1, _ := bpm.NewPage()
	page1 := guard1.page.ID
	guard1.Drop()

	// Main thread holds write lock on page 0
	// (guard0 is still held)

	// Signal for coordination
	var started atomic.Bool

	// Spawn a child goroutine that will try to acquire page 0
	done := make(chan bool)
	go func() {
		started.Store(true)
		// This will block waiting for page 0's frame lock
		childGuard, _ := bpm.WritePage(page0)
		childGuard.Drop()
		done <- true
	}()

	// Wait for child to start
	for !started.Load() {
		time.Sleep(time.Millisecond)
	}

	// Give the child time to block on page 0
	time.Sleep(100 * time.Millisecond)

	// This is the critical test - if Level 2 is implemented wrong, this hangs
	writeGuard1, err := bpm.WritePage(page1)
	if err != nil {
		t.Fatalf("WritePage(page1) failed: %v", err)
	}
	writeGuard1.Drop()

	// Release page 0 so child can finish
	guard0.Drop()

	// Wait for child to complete (with timeout)
	select {
	case <-done:
		// Success
	case <-time.After(5 * time.Second):
		t.Fatal("deadlock detected - child goroutine never completed")
	}
}

func TestContention(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	const numGoroutines = 4
	const iterations = 10000

	// Create a single page that all goroutines will fight over
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	// Channel to signal completion
	done := make(chan bool, numGoroutines)

	// Spawn multiple goroutines all writing to the same page
	for i := 0; i < numGoroutines; i++ {
		go func(id int) {
			for j := 0; j < iterations; j++ {
				writeGuard, err := bpm.WritePage(pageID)
				if err != nil {
					t.Errorf("goroutine %d: WritePage failed: %v", id, err)
					done <- false
					return
				}
				// Write some data (just to do something)
				writeGuard.page.Data[0] = byte(id)
				writeGuard.Drop()
			}
			done <- true
		}(i)
	}

	// Wait for all goroutines to complete
	for i := 0; i < numGoroutines; i++ {
		select {
		case success := <-done:
			if !success {
				t.Fatal("a goroutine failed")
			}
		case <-time.After(30 * time.Second):
			t.Fatal("timeout - possible deadlock under contention")
		}
	}
}

func TestPageAccess(t *testing.T) {
	bpm, cleanup := setupBPM(t, 1)
	defer cleanup()

	const rounds = 50

	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	// Writer goroutine - keeps updating the page
	go func() {
		for i := 0; i < rounds; i++ {
			time.Sleep(5 * time.Millisecond)
			writeGuard, _ := bpm.WritePage(pageID)
			// Write the current iteration number to the page
			writeGuard.page.Data[0] = byte(i)
			writeGuard.Drop()
		}
	}()

	// Main thread - reader
	for i := 0; i < rounds; i++ {
		// Wait a bit to let writer potentially write
		time.Sleep(10 * time.Millisecond)

		// Take read lock
		readGuard, _ := bpm.ReadPage(pageID)

		// Save what we see
		snapshot := readGuard.page.Data[0]

		// Sleep while holding the read lock
		// If locking works, the writer cannot modify the page during this time
		time.Sleep(10 * time.Millisecond)

		// Check data hasn't changed
		if readGuard.page.Data[0] != snapshot {
			t.Fatalf("data changed while holding read lock! was %d, now %d", snapshot, readGuard.page.Data[0])
		}

		readGuard.Drop()
	}
}

func TestEvictable(t *testing.T) {
	// Single frame buffer pool - forces eviction attempts
	bpm, cleanup := setupBPM(t, 1)
	defer cleanup()

	const rounds = 100
	const numReaders = 4

	for round := 0; round < rounds; round++ {
		// Create two pages - only one can be in memory at a time
		winnerGuard, _ := bpm.NewPage()
		winnerID := winnerGuard.page.ID
		winnerGuard.Drop()

		loserGuard, _ := bpm.NewPage()
		loserID := loserGuard.page.ID
		loserGuard.Drop()

		// Winner is now evicted (loser took the only frame)
		// Bring winner back in
		mainGuard, _ := bpm.ReadPage(winnerID)

		// Now: winner is in the only frame, pinned by mainGuard
		// loser is on disk

		// Spawn readers that will also read the winner page
		var wg sync.WaitGroup
		wg.Add(numReaders)

		for i := 0; i < numReaders; i++ {
			go func() {
				defer wg.Done()

				// Read the winner page (should succeed - it's in memory)
				readGuard, err := bpm.ReadPage(winnerID)
				if err != nil {
					t.Errorf("ReadPage(winner) failed: %v", err)
					return
				}

				// While holding the read lock, try to bring in the loser
				// This should fail - the only frame is pinned
				loserReadGuard, err := bpm.ReadPage(loserID)
				if err == nil {
					// This shouldn't happen - where did loser go?
					// The only frame is pinned by winner
					loserReadGuard.Drop()
					t.Errorf("ReadPage(loser) should have failed - no evictable frames")
				}

				readGuard.Drop()
			}()
		}

		wg.Wait()
		mainGuard.Drop()
	}
}

// Benchmarks

func BenchmarkSequentialRead(b *testing.B) {
	tmpFile, _ := os.CreateTemp("", "bpm_bench_*.db")
	tmpFile.Close()
	dm, _ := disk.NewDiskManager(tmpFile.Name())
	scheduler := disk.NewDiskScheduler(dm)
	bpm := NewBufferPoolManager(10, dm, scheduler)

	defer func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}()

	// Create a page to read
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		readGuard, _ := bpm.ReadPage(pageID)
		readGuard.Drop()
	}
}

func BenchmarkSequentialWrite(b *testing.B) {
	tmpFile, _ := os.CreateTemp("", "bpm_bench_*.db")
	tmpFile.Close()
	dm, _ := disk.NewDiskManager(tmpFile.Name())
	scheduler := disk.NewDiskScheduler(dm)
	bpm := NewBufferPoolManager(10, dm, scheduler)

	defer func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}()

	// Create a page to write
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		writeGuard, _ := bpm.WritePage(pageID)
		writeGuard.Drop()
	}
}

func BenchmarkParallelRead(b *testing.B) {
	tmpFile, _ := os.CreateTemp("", "bpm_bench_*.db")
	tmpFile.Close()
	dm, _ := disk.NewDiskManager(tmpFile.Name())
	scheduler := disk.NewDiskScheduler(dm)
	bpm := NewBufferPoolManager(10, dm, scheduler)

	defer func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}()

	// Create a page to read
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			readGuard, _ := bpm.ReadPage(pageID)
			readGuard.Drop()
		}
	})
}

func BenchmarkParallelWrite(b *testing.B) {
	tmpFile, _ := os.CreateTemp("", "bpm_bench_*.db")
	tmpFile.Close()
	dm, _ := disk.NewDiskManager(tmpFile.Name())
	scheduler := disk.NewDiskScheduler(dm)
	bpm := NewBufferPoolManager(10, dm, scheduler)

	defer func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}()

	// Create a page to write
	guard, _ := bpm.NewPage()
	pageID := guard.page.ID
	guard.Drop()

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			writeGuard, _ := bpm.WritePage(pageID)
			writeGuard.Drop()
		}
	})
}
