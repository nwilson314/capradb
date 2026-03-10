package heap

import (
	"os"
	"testing"

	"capradb/storage/buffer"
	"capradb/storage/disk"
	"capradb/storage/page"
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

func TestTableHeap_InsertRecord(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	if recordID.PageID != 1 || recordID.SlotID != 0 {
		t.Errorf("expected pageID 1 and slotID 0, got %d and %d", recordID.PageID, recordID.SlotID)
	}
}

func TestTableHeap_InsertRecord_SpansMultiplePages(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	// Each record is 1000 bytes. Page is 4096 bytes with 12 byte header.
	// Each insert needs record + 4 byte slot = 1004 bytes.
	// So ~4 records should fill a page.
	bigRecord := make([]byte, 1000)
	for i := range bigRecord {
		bigRecord[i] = byte(i % 256)
	}

	var rids []page.RID
	firstPageID := uint32(0)

	for i := 0; i < 10; i++ {
		rid, err := heap.InsertRecord(bigRecord)
		if err != nil {
			t.Fatalf("InsertRecord %d failed: %v", i, err)
		}
		rids = append(rids, rid)

		if i == 0 {
			firstPageID = rid.PageID
		}
	}

	// Should have spanned to at least one new page
	lastRID := rids[len(rids)-1]
	if lastRID.PageID == firstPageID {
		t.Errorf("expected records to span multiple pages, but all on page %d", firstPageID)
	}

	// Verify slot IDs reset on new page
	foundNewPageSlotZero := false
	for _, rid := range rids {
		if rid.PageID != firstPageID && rid.SlotID == 0 {
			foundNewPageSlotZero = true
			break
		}
	}
	if !foundNewPageSlotZero {
		t.Error("expected to find slotID 0 on a new page")
	}
}

func TestTableHeap_GetRecord(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	recordData, err := heap.GetRecord(recordID)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}

	if string(recordData) != string(record) {
		t.Errorf("expected %s, got %s", record, recordData)
	}
}

func TestTableHeap_GetRecord_SpanningPages(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	// Each record is 1000 bytes. Page is 4096 bytes with 12 byte header.
	// Each insert needs record + 4 byte slot = 1004 bytes.
	// So ~4 records should fill a page.
	bigRecord := make([]byte, 1000)
	for i := range bigRecord {
		bigRecord[i] = byte(i % 256)
	}

	record2 := []byte("hello world 2")
	recordID2, err := heap.InsertRecord(record2)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	if recordID2.PageID != recordID.PageID {
		t.Errorf("expected pageID %d, got %d", recordID.PageID, recordID2.PageID)
	}

	recordData, err := heap.GetRecord(recordID)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}

	if string(recordData) != string(record) {
		t.Errorf("expected %s, got %s", record, recordData)
	}

	recordData2, err := heap.GetRecord(recordID2)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}

	if string(recordData2) != string(record2) {
		t.Errorf("expected %s, got %s", record2, recordData2)
	}
}

func TestTableHeap_DeleteRecord(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	err = heap.DeleteRecord(recordID)
	if err != nil {
		t.Fatalf("DeleteRecord failed: %v", err)
	}

	_, get_err := heap.GetRecord(recordID)
	if get_err == nil {
		t.Errorf("expected error, got nil")
	}
}

func TestNewTableIterator(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	iterator, err := NewTableIterator(heap)
	if err != nil {
		t.Fatalf("NewTableIterator failed: %v", err)
	}

	if iterator == nil {
		t.Fatal("expected non-nil TableIterator")
	}
}

func TestTableIterator_Next(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	iterator, err := NewTableIterator(heap)
	if err != nil {
		t.Fatalf("NewTableIterator failed: %v", err)
	}

	recordData, _, err := iterator.Next()
	if err != nil {
		t.Fatalf("Next failed: %v", err)
	}
	if string(recordData) != string(record) {
		t.Errorf("expected %s, got %s", record, recordData)
	}

	recordDataHeap, err := heap.GetRecord(recordID)
	if err != nil {
		t.Fatalf("GetRecord failed: %v", err)
	}
	if string(recordDataHeap) != string(recordData) {
		t.Errorf("iterator and get record data mismatch: expected %s, got %s", recordData, recordDataHeap)
	}
	iterator.Close() // drop the page guards
}

func TestTableIterator_Next_DeletedSlot(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	record := []byte("hello world")
	recordID, err := heap.InsertRecord(record)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	record2 := []byte("hello world 2")
	_, err = heap.InsertRecord(record2)
	if err != nil {
		t.Fatalf("InsertRecord failed: %v", err)
	}

	err = heap.DeleteRecord(recordID)
	if err != nil {
		t.Fatalf("DeleteRecord failed: %v", err)
	}

	iterator, err := NewTableIterator(heap)
	if err != nil {
		t.Fatalf("NewTableIterator failed: %v", err)
	}

	// Iterator should skip the deleted slot and return the next record
	recordData, _, err := iterator.Next()
	if err != nil {
		t.Fatalf("Next failed: %v", err)
	}
	if string(recordData) != string(record2) {
		t.Errorf("expected %s, got %s", record2, recordData)
	}
	iterator.Close()
}

func TestTableIterator_MultiplePages(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	// Insert 10 large records that will span multiple pages
	// 1000 bytes + 4 byte slot = 1004 bytes per record
	// ~4 records per page, so 10 records = 3 pages
	type insertedRecord struct {
		data []byte
		rid  page.RID
	}

	var records []insertedRecord
	for i := 0; i < 10; i++ {
		data := make([]byte, 1000)
		// Make each record unique
		data[0] = byte(i)
		data[999] = byte(i)

		rid, err := heap.InsertRecord(data)
		if err != nil {
			t.Fatalf("InsertRecord %d failed: %v", i, err)
		}
		records = append(records, insertedRecord{data: data, rid: rid})
	}

	// Iterate and verify we get all records back in order
	iterator, err := NewTableIterator(heap)
	if err != nil {
		t.Fatalf("NewTableIterator failed: %v", err)
	}

	count := 0
	for {
		data, rid, err := iterator.Next()
		if err != nil {
			break // EOF
		}

		if count >= len(records) {
			t.Fatalf("iterator returned more records than inserted")
		}

		expected := records[count]
		if rid.PageID != expected.rid.PageID || rid.SlotID != expected.rid.SlotID {
			t.Errorf("record %d: expected RID (%d,%d), got (%d,%d)",
				count, expected.rid.PageID, expected.rid.SlotID, rid.PageID, rid.SlotID)
		}
		if data[0] != expected.data[0] || data[999] != expected.data[999] {
			t.Errorf("record %d: data mismatch", count)
		}
		count++
	}

	if count != 10 {
		t.Errorf("expected 10 records from iterator, got %d", count)
	}
	iterator.Close()
}

func BenchmarkTableScan(b *testing.B) {
	tmpFile, _ := os.CreateTemp("", "heap_bench_*.db")
	tmpFile.Close()

	dm, _ := disk.NewDiskManager(tmpFile.Name())
	scheduler := disk.NewDiskScheduler(dm)
	bpm := buffer.NewBufferPoolManager(10, dm, scheduler)

	defer func() {
		scheduler.Shutdown()
		dm.Close()
		os.Remove(tmpFile.Name())
	}()

	heap, _ := NewTableHeap(bpm)

	// Insert records: 100 byte records, ~36 per page
	// Fill 200 pages = ~7200 records
	record := make([]byte, 100)
	for i := range record {
		record[i] = byte(i % 256)
	}

	numRecords := 7000
	for i := 0; i < numRecords; i++ {
		record[0] = byte(i % 256)
		record[1] = byte(i / 256)
		_, err := heap.InsertRecord(record)
		if err != nil {
			b.Fatalf("InsertRecord %d failed: %v", i, err)
		}
	}

	b.ResetTimer()

	for n := 0; n < b.N; n++ {
		iterator, err := NewTableIterator(heap)
		if err != nil {
			b.Fatalf("NewTableIterator failed: %v", err)
		}

		count := 0
		for {
			_, _, err := iterator.Next()
			if err != nil {
				break
			}
			count++
		}
		iterator.Close()

		if count != numRecords {
			b.Fatalf("expected %d records, got %d", numRecords, count)
		}
	}

	b.ReportMetric(float64(numRecords), "records/scan")
}

func TestTableIterator_AllDeleted(t *testing.T) {
	bpm, cleanup := setupBPM(t, 10)
	defer cleanup()

	heap, err := NewTableHeap(bpm)
	if err != nil {
		t.Fatalf("NewTableHeap failed: %v", err)
	}

	// Insert 3 records, delete all of them
	var rids []page.RID
	for i := 0; i < 3; i++ {
		rid, err := heap.InsertRecord([]byte("doomed"))
		if err != nil {
			t.Fatalf("InsertRecord failed: %v", err)
		}
		rids = append(rids, rid)
	}

	for _, rid := range rids {
		err := heap.DeleteRecord(rid)
		if err != nil {
			t.Fatalf("DeleteRecord failed: %v", err)
		}
	}

	// Iterator should return EOF immediately
	iterator, err := NewTableIterator(heap)
	if err != nil {
		t.Fatalf("NewTableIterator failed: %v", err)
	}

	_, _, err = iterator.Next()
	if err == nil {
		t.Error("expected EOF from iterator on fully deleted heap")
	}
	iterator.Close()
}
