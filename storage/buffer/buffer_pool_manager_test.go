package buffer

import (
	"os"
	"testing"

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
	pageID, err := bpm.NewPage()
	if err != nil {
		t.Fatalf("NewPage failed: %v", err)
	}

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
}

func TestFetchPageInMemory(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	// Create a page first
	pageID, _ := bpm.NewPage()

	// Fetch the same page - should come from memory, not disk
	page, err := bpm.FetchPage(pageID)
	if err != nil {
		t.Fatalf("FetchPage failed: %v", err)
	}

	if page == nil {
		t.Fatal("expected non-nil page")
	}

	if page.ID != pageID {
		t.Errorf("expected page ID %d, got %d", pageID, page.ID)
	}

	// Pin count should now be 2 (NewPage + FetchPage)
	pinCount, _ := bpm.GetPinCount(pageID)
	if pinCount != 2 {
		t.Errorf("expected pin count 2, got %d", pinCount)
	}
}

func TestUnpinPage(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	pageID, _ := bpm.NewPage()

	// Pin count starts at 1
	pinCount, _ := bpm.GetPinCount(pageID)
	if pinCount != 1 {
		t.Errorf("expected pin count 1, got %d", pinCount)
	}

	// Unpin the page
	ok := bpm.UnpinPage(pageID, false)
	if !ok {
		t.Error("UnpinPage returned false")
	}

	// Pin count should now be 0
	pinCount, _ = bpm.GetPinCount(pageID)
	if pinCount != 0 {
		t.Errorf("expected pin count 0, got %d", pinCount)
	}
}

func TestUnpinPageDirty(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	pageID, _ := bpm.NewPage()

	// Unpin and mark dirty
	bpm.UnpinPage(pageID, true)

	// Verify it's marked dirty
	frameID := bpm.pageToFrame[pageID]
	if !bpm.frameHeaders[frameID].dirty {
		t.Error("expected frame to be marked dirty")
	}
}

func TestEviction(t *testing.T) {
	// Small pool to force eviction
	bpm, cleanup := setupBPM(t, 3)
	defer cleanup()

	// Fill up the buffer pool
	page0, _ := bpm.NewPage() // page 0 in frame
	page1, _ := bpm.NewPage() // page 1 in frame
	page2, _ := bpm.NewPage() // page 2 in frame

	// Write some data to page0 so we can verify persistence
	p0, _ := bpm.FetchPage(page0)
	p0.InsertRecord([]byte("hello from page 0"))

	// Unpin all pages (makes them evictable)
	// page0 has pin count 2 (NewPage + FetchPage), so unpin twice
	bpm.UnpinPage(page0, true) // mark dirty since we wrote data
	bpm.UnpinPage(page0, false)
	bpm.UnpinPage(page1, false)
	bpm.UnpinPage(page2, false)

	// Verify all have pin count 0
	for _, pid := range []uint32{page0, page1, page2} {
		pc, _ := bpm.GetPinCount(pid)
		if pc != 0 {
			t.Errorf("expected pin count 0 for page %d, got %d", pid, pc)
		}
	}

	// Now create a new page - this MUST evict something
	page3, err := bpm.NewPage()
	if err != nil {
		t.Fatalf("NewPage failed after eviction should have worked: %v", err)
	}

	// We should have 3 pages in memory, one was evicted
	if len(bpm.pageToFrame) != 3 {
		t.Errorf("expected 3 pages in memory, got %d", len(bpm.pageToFrame))
	}

	// page3 should definitely be in memory
	if _, ok := bpm.pageToFrame[page3]; !ok {
		t.Error("page3 should be in memory")
	}

	// Unpin page3 so we can potentially evict it
	bpm.UnpinPage(page3, false)

	// Now fetch page0 - it should come from disk (was evicted and dirty)
	p0Again, err := bpm.FetchPage(page0)
	if err != nil {
		t.Fatalf("FetchPage(page0) failed: %v", err)
	}

	// Verify the data we wrote persisted
	record, err := p0Again.GetRecord(0)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}

	if string(record) != "hello from page 0" {
		t.Errorf("expected 'hello from page 0', got '%s'", string(record))
	}
}

func TestFlushPage(t *testing.T) {
	bpm, cleanup := setupBPM(t, 3)
	defer cleanup()

	// Create a page and write data
	pageID, _ := bpm.NewPage()
	p, _ := bpm.FetchPage(pageID)
	p.InsertRecord([]byte("flush me"))
	bpm.UnpinPage(pageID, true) // mark dirty
	bpm.UnpinPage(pageID, false)

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
		pid, _ := bpm.NewPage()
		pages = append(pages, pid)
		p, _ := bpm.FetchPage(pid)
		p.InsertRecord([]byte("data"))
		bpm.UnpinPage(pid, true) // dirty
		bpm.UnpinPage(pid, false)
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

	pageID, _ := bpm.NewPage()

	// Can't delete a pinned page
	ok := bpm.DeletePage(pageID)
	if ok {
		t.Error("should not be able to delete pinned page")
	}

	// Unpin it
	bpm.UnpinPage(pageID, false)

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
