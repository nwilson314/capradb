package disk

import (
	"os"
	"testing"

	"capradb/storage/page"
)

func TestDiskScheduler_New(t *testing.T) {
	path := "test_scheduler_new.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatal(err)
	}
	defer dm.Close()

	scheduler := NewDiskScheduler(dm)
	if scheduler == nil {
		t.Fatal("expected non-nil scheduler")
	}
	scheduler.Shutdown()
}

func TestDiskScheduler_WriteReadPage(t *testing.T) {
	// Port of CMU's ScheduleWriteReadPageTest
	path := "test_scheduler_rw.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatal(err)
	}
	defer dm.Close()

	scheduler := NewDiskScheduler(dm)
	defer scheduler.Shutdown()

	// Allocate a page
	pageID := dm.AllocatePage()

	// Create write request
	writePage := &page.Page{ID: pageID}
	copy(writePage.Data[:], []byte("A test string."))

	writeReq := DiskRequest{
		IsWrite: true,
		PageID:  pageID,
		Page:    writePage,
		Done:    make(chan bool, 1),
	}

	// Schedule write, wait for it
	scheduler.Schedule([]DiskRequest{writeReq})
	if success := <-writeReq.Done; !success {
		t.Fatal("write failed")
	}

	// Create read request
	readPage := &page.Page{ID: pageID}
	readReq := DiskRequest{
		IsWrite: false,
		PageID:  pageID,
		Page:    readPage,
		Done:    make(chan bool, 1),
	}

	// Schedule read, wait for it
	scheduler.Schedule([]DiskRequest{readReq})
	if success := <-readReq.Done; !success {
		t.Fatal("read failed")
	}

	// Verify data matches
	if string(readPage.Data[:14]) != "A test string." {
		t.Errorf("expected 'A test string.', got '%s'", string(readPage.Data[:14]))
	}
}

func TestDiskScheduler_BatchRequests(t *testing.T) {
	path := "test_scheduler_batch.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatal(err)
	}
	defer dm.Close()

	scheduler := NewDiskScheduler(dm)
	defer scheduler.Shutdown()

	// Create multiple write requests
	const numPages = 10
	writeReqs := make([]DiskRequest, numPages)

	for i := 0; i < numPages; i++ {
		pageID := dm.AllocatePage()
		p := &page.Page{ID: pageID}
		p.Data[0] = byte(i)

		writeReqs[i] = DiskRequest{
			IsWrite: true,
			PageID:  pageID,
			Page:    p,
			Done:    make(chan bool, 1),
		}
	}

	// Schedule all writes as a batch
	scheduler.Schedule(writeReqs)

	// Wait for all writes
	for i, req := range writeReqs {
		if success := <-req.Done; !success {
			t.Fatalf("write %d failed", i)
		}
	}

	// Create read requests
	readReqs := make([]DiskRequest, numPages)
	for i := uint32(0); i < numPages; i++ {
		p := &page.Page{ID: i}
		readReqs[i] = DiskRequest{
			IsWrite: false,
			PageID:  i,
			Page:    p,
			Done:    make(chan bool, 1),
		}
	}

	// Schedule all reads as a batch
	scheduler.Schedule(readReqs)

	// Wait and verify all reads
	for i, req := range readReqs {
		if success := <-req.Done; !success {
			t.Fatalf("read %d failed", i)
		}
		if req.Page.Data[0] != byte(i) {
			t.Errorf("page %d: expected data[0]=%d, got %d", i, i, req.Page.Data[0])
		}
	}
}
