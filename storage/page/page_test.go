package page

import (
	"bytes"
	"testing"
)

func TestPage_Init(t *testing.T) {
	p := New(1)
	if p.ID != 1 {
		t.Errorf("expected ID 1, got %d", p.ID)
	}
	if p.GetSlotCount() != 0 {
		t.Errorf("expected 0 slots, got %d", p.GetSlotCount())
	}
	// Free space should be PageSize - HeaderSize
	expectedFree := int(PageSize - HeaderSize)
	if int(p.GetFreeSpacePointer()) != PageSize {
		// Wait, pointer points to END of page initially?
		// Or points to start of data?
		// Standard: Pointer points to the START of the data area.
		// Initially, data area starts at 4096.
		t.Errorf("expected free space pointer at 4096, got %d", p.GetFreeSpacePointer())
	}

	// Real free space available:
	if p.GetFreeSpace() != expectedFree {
		t.Errorf("expected free space %d, got %d", expectedFree, p.GetFreeSpace())
	}
}

func TestPage_InsertRecord(t *testing.T) {
	p := New(1)
	data := []byte("hello world") // 11 bytes

	slotID, err := p.InsertRecord(data)
	if err != nil {
		t.Fatalf("insert failed: %v", err)
	}
	if slotID != 0 {
		t.Errorf("expected slot 0, got %d", slotID)
	}

	if p.GetSlotCount() != 1 {
		t.Errorf("expected 1 slot, got %d", p.GetSlotCount())
	}

	// Verify Data Retrieval
	retrieved, _ := p.GetRecord(slotID)
	if !bytes.Equal(retrieved, data) {
		t.Errorf("expected %s, got %s", data, retrieved)
	}
}

func TestPage_MultipleInserts(t *testing.T) {
	p := New(1)

	// Insert A (1 byte)
	id1, _ := p.InsertRecord([]byte("A"))
	// Insert B (1 byte)
	id2, _ := p.InsertRecord([]byte("B"))

	if id1 != 0 || id2 != 1 {
		t.Errorf("expected ids 0 and 1, got %d and %d", id1, id2)
	}

	// Verify Layout Logic (optional but good for debugging)
	// Slot 0 should point to 4095 (4096 - 1)
	// Slot 1 should point to 4094 (4095 - 1)

	rec1, _ := p.GetRecord(0)
	if string(rec1) != "A" {
		t.Errorf("expected A, got %s", rec1)
	}

	rec2, _ := p.GetRecord(1)
	if string(rec2) != "B" {
		t.Errorf("expected B, got %s", rec2)
	}
}

func TestPage_NoSpace(t *testing.T) {
	p := New(1)

	// Header is 12 bytes.
	// We need 4 bytes for the slot.
	// So overhead is 16 bytes.
	// Max data = 4096 - 16 = 4080.

	largeData := make([]byte, 4081)
	_, err := p.InsertRecord(largeData)
	if err == nil {
		t.Error("expected error for too large record")
	}

	justRight := make([]byte, 4080)
	_, err = p.InsertRecord(justRight)
	if err != nil {
		t.Errorf("expected success for 4080 bytes, got %v", err)
	}
}

func TestPage_GetRecord_InvalidSlot(t *testing.T) {
	p := New(1)

	// No records inserted yet - any slot ID should fail
	_, err := p.GetRecord(-1)
	if err == nil {
		t.Error("expected error for negative slot ID")
	}

	_, err = p.GetRecord(0)
	if err == nil {
		t.Error("expected error for slot 0 when page is empty")
	}

	_, err = p.GetRecord(100)
	if err == nil {
		t.Error("expected error for slot 100 when page is empty")
	}

	// Insert one record
	p.InsertRecord([]byte("test"))

	// Slot 0 should work now
	data, err := p.GetRecord(0)
	if err != nil {
		t.Errorf("expected success for slot 0, got %v", err)
	}
	if string(data) != "test" {
		t.Errorf("expected 'test', got '%s'", data)
	}

	// Slot 1 should still fail
	_, err = p.GetRecord(1)
	if err == nil {
		t.Error("expected error for slot 1 when only 1 record exists")
	}
}

func TestPage_UpdateRecord_SameSize(t *testing.T) {
	p := New(1)

	slotID, _ := p.InsertRecord([]byte("hello"))

	// Update with same size data
	err := p.UpdateRecord(slotID, []byte("world"))
	if err != nil {
		t.Fatalf("update failed: %v", err)
	}

	data, _ := p.GetRecord(slotID)
	if string(data) != "world" {
		t.Errorf("expected 'world', got '%s'", data)
	}
}

func TestPage_UpdateRecord_Smaller(t *testing.T) {
	p := New(1)

	slotID, _ := p.InsertRecord([]byte("hello"))

	// Update with smaller data
	err := p.UpdateRecord(slotID, []byte("hi"))
	if err != nil {
		t.Fatalf("update failed: %v", err)
	}

	data, _ := p.GetRecord(slotID)
	if string(data) != "hi" {
		t.Errorf("expected 'hi', got '%s'", data)
	}
}

func TestPage_UpdateRecord_Larger_Fits(t *testing.T) {
	p := New(1)

	slotID, _ := p.InsertRecord([]byte("hi"))

	freeSpaceBefore := p.GetFreeSpace()

	// Update with larger data (should still fit in page)
	err := p.UpdateRecord(slotID, []byte("hello world"))
	if err != nil {
		t.Fatalf("update failed: %v", err)
	}

	data, _ := p.GetRecord(slotID)
	if string(data) != "hello world" {
		t.Errorf("expected 'hello world', got '%s'", data)
	}

	// Free space should have decreased
	freeSpaceAfter := p.GetFreeSpace()
	if freeSpaceAfter >= freeSpaceBefore {
		t.Errorf("expected free space to decrease, before=%d after=%d", freeSpaceBefore, freeSpaceAfter)
	}
}

func TestPage_UpdateRecord_Larger_NoSpace(t *testing.T) {
	p := New(1)

	// Fill up the page mostly
	p.InsertRecord(make([]byte, 2000))
	slotID, _ := p.InsertRecord([]byte("small"))
	p.InsertRecord(make([]byte, 2000))

	// Try to update "small" to something that won't fit
	err := p.UpdateRecord(slotID, make([]byte, 500))
	if err == nil {
		t.Error("expected error when update doesn't fit")
	}

	// Original data should be unchanged
	data, _ := p.GetRecord(slotID)
	if string(data) != "small" {
		t.Errorf("expected original 'small' after failed update, got '%s'", data)
	}
}

func TestPage_UpdateRecord_InvalidSlot(t *testing.T) {
	p := New(1)
	p.InsertRecord([]byte("test"))

	err := p.UpdateRecord(-1, []byte("new"))
	if err == nil {
		t.Error("expected error for negative slot ID")
	}

	err = p.UpdateRecord(5, []byte("new"))
	if err == nil {
		t.Error("expected error for non-existent slot")
	}
}

func TestPage_NoSpace_SlotOverhead(t *testing.T) {
	p := New(1)

	// Insert several small records first
	// Each insert consumes: 4 bytes (slot) + data length
	for i := 0; i < 10; i++ {
		_, err := p.InsertRecord([]byte("small"))
		if err != nil {
			t.Fatalf("small insert %d failed: %v", i, err)
		}
	}

	// After 10 inserts:
	// - Slots used: 10 * 4 = 40 bytes
	// - Data used: 10 * 5 = 50 bytes
	// - Total used: 12 (header) + 40 (slots) + 50 (data) = 102 bytes
	// - Free space: 4096 - 102 = 3994 bytes
	//
	// But the NEXT insert needs 4 more bytes for its slot!
	// So max data for next record = 3994 - 4 = 3990 bytes

	freeSpace := p.GetFreeSpace()
	t.Logf("Free space after 10 inserts: %d", freeSpace)

	// This should fail - it would fit if we ignore slot overhead
	tooBig := make([]byte, freeSpace)
	_, err := p.InsertRecord(tooBig)
	if err == nil {
		t.Error("expected error: record fits in free space but not with slot overhead")
	}

	// This should succeed - accounts for the new slot
	justRight := make([]byte, freeSpace-SlotSize)
	_, err = p.InsertRecord(justRight)
	if err != nil {
		t.Errorf("expected success for %d bytes, got %v", len(justRight), err)
	}
}
