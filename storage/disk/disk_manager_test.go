package disk

import (
	"os"
	"testing"

	"capradb/storage/page"
)

func TestDiskManager_CreateNew(t *testing.T) {
	path := "test_create.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to create disk manager: %v", err)
	}
	defer dm.Close()

	if dm.GetNumPages() != 0 {
		t.Errorf("expected 0 pages, got %d", dm.GetNumPages())
	}
}

func TestDiskManager_AllocateAndWrite(t *testing.T) {
	path := "test_allocate.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to create disk manager: %v", err)
	}
	defer dm.Close()

	// Allocate a page
	pageID := dm.AllocatePage()
	if pageID != 0 {
		t.Errorf("expected first page ID to be 0, got %d", pageID)
	}

	if dm.GetNumPages() != 1 {
		t.Errorf("expected 1 page, got %d", dm.GetNumPages())
	}

	// Create a page and write some data
	p := page.New(pageID)
	p.InsertRecord([]byte("hello disk"))

	err = dm.WritePage(p)
	if err != nil {
		t.Fatalf("failed to write page: %v", err)
	}
}

func TestDiskManager_WriteAndRead(t *testing.T) {
	path := "test_readwrite.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to create disk manager: %v", err)
	}
	defer dm.Close()

	// Allocate and write
	pageID := dm.AllocatePage()
	p := page.New(pageID)
	p.InsertRecord([]byte("test data"))

	err = dm.WritePage(p)
	if err != nil {
		t.Fatalf("failed to write page: %v", err)
	}

	// Read it back
	readPage, err := dm.ReadPage(pageID)
	if err != nil {
		t.Fatalf("failed to read page: %v", err)
	}

	record, err := readPage.GetRecord(0)
	if err != nil {
		t.Fatalf("failed to get record: %v", err)
	}

	if string(record) != "test data" {
		t.Errorf("expected 'test data', got '%s'", record)
	}
}

func TestDiskManager_Persistence(t *testing.T) {
	path := "test_persist.db"
	defer os.Remove(path)

	// Create, write, close
	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to create disk manager: %v", err)
	}

	pageID := dm.AllocatePage()
	p := page.New(pageID)
	p.InsertRecord([]byte("persistent data"))
	dm.WritePage(p)
	dm.Close()

	// Reopen and read
	dm2, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to reopen disk manager: %v", err)
	}
	defer dm2.Close()

	if dm2.GetNumPages() != 1 {
		t.Errorf("expected 1 page after reopen, got %d", dm2.GetNumPages())
	}

	readPage, err := dm2.ReadPage(pageID)
	if err != nil {
		t.Fatalf("failed to read page: %v", err)
	}

	record, _ := readPage.GetRecord(0)
	if string(record) != "persistent data" {
		t.Errorf("expected 'persistent data', got '%s'", record)
	}
}

func TestDiskManager_MultiplePages(t *testing.T) {
	path := "test_multi.db"
	defer os.Remove(path)

	dm, err := NewDiskManager(path)
	if err != nil {
		t.Fatalf("failed to create disk manager: %v", err)
	}
	defer dm.Close()

	// Allocate and write 3 pages
	for i := 0; i < 3; i++ {
		pageID := dm.AllocatePage()
		p := page.New(pageID)
		p.InsertRecord([]byte{byte('A' + i)}) // A, B, C
		dm.WritePage(p)
	}

	if dm.GetNumPages() != 3 {
		t.Errorf("expected 3 pages, got %d", dm.GetNumPages())
	}

	// Read them back in reverse order
	for i := 2; i >= 0; i-- {
		p, err := dm.ReadPage(uint32(i))
		if err != nil {
			t.Fatalf("failed to read page %d: %v", i, err)
		}
		record, _ := p.GetRecord(0)
		expected := byte('A' + i)
		if record[0] != expected {
			t.Errorf("page %d: expected '%c', got '%c'", i, expected, record[0])
		}
	}
}
