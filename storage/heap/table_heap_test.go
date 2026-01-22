package heap

import (
	"os"
	"testing"

	"capradb/storage/buffer"
	"capradb/storage/disk"
)

func setupBPM(t *testing.T, poolSize uint32) (*buffer.BufferPoolManager, func()) {
	tmpFile, err := os.CreateTemp("", "heap_test_*.db")
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
	bpm := buffer.NewBufferPoolManager(poolSize, dm, scheduler)

	cleanup := func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}

	return bpm, cleanup
}

func TestNewTableHeap(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	if heap == nil {
		t.Fatal("expected non-nil TableHeap")
	}

	// Header page should have been allocated (page 0)
	if heap.headerPageID != 0 {
		t.Errorf("expected headerPageID=0, got %d", heap.headerPageID)
	}
}
