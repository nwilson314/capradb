package replacer

import "testing"

func TestARC_New(t *testing.T) {
	arc := NewARC(3)
	if arc == nil {
		t.Fatal("expected non-nil ARC")
	}
}

func TestARC_RecordAccess_AddsToT1(t *testing.T) {
	arc := NewARC(3)

	arc.RecordAccess(1, 1)

	// Should be in T1
	if arc.t1.Len() != 1 {
		t.Errorf("expected t1 length 1, got %d", arc.t1.Len())
	}
	if _, ok := arc.t1Index[1]; !ok {
		t.Error("expected pageID 1 in t1Index")
	}
}

func TestARC_RecordAccess_PromotesToT2(t *testing.T) {
	arc := NewARC(3)

	// First access - goes to T1
	arc.RecordAccess(1, 1)
	if arc.t1.Len() != 1 {
		t.Errorf("expected t1 length 1, got %d", arc.t1.Len())
	}

	// Second access - should promote to T2
	arc.RecordAccess(1, 1)
	if arc.t1.Len() != 0 {
		t.Errorf("expected t1 length 0 after promotion, got %d", arc.t1.Len())
	}
	if arc.t2.Len() != 1 {
		t.Errorf("expected t2 length 1 after promotion, got %d", arc.t2.Len())
	}
	if _, ok := arc.t2Index[1]; !ok {
		t.Error("expected pageID 1 in t2Index")
	}
}

func TestARC_RecordAccess_MultiplePages(t *testing.T) {
	arc := NewARC(3)

	arc.RecordAccess(1, 10)
	arc.RecordAccess(2, 20)
	arc.RecordAccess(3, 30)

	if arc.t1.Len() != 3 {
		t.Errorf("expected t1 length 3, got %d", arc.t1.Len())
	}

	// Check frameToPage mapping
	if arc.frameToPage[1] != 10 {
		t.Errorf("expected frame 1 -> page 10, got %d", arc.frameToPage[1])
	}
	if arc.frameToPage[2] != 20 {
		t.Errorf("expected frame 2 -> page 20, got %d", arc.frameToPage[2])
	}
}

func TestARC_BasicEviction(t *testing.T) {
	arc := NewARC(3)

	// Add 3 pages, all evictable
	arc.RecordAccess(1, 1) // frame 1, page 1
	arc.RecordAccess(2, 2)
	arc.RecordAccess(3, 3)
	arc.SetEvictable(1, true)
	arc.SetEvictable(2, true)
	arc.SetEvictable(3, true)

	if arc.Size() != 3 {
		t.Errorf("expected size 3, got %d", arc.Size())
	}

	// Evict in LRU order from T1
	frameID, ok := arc.Evict()
	if !ok || frameID != 1 {
		t.Errorf("expected frame 1, got %d", frameID)
	}

	frameID, ok = arc.Evict()
	if !ok || frameID != 2 {
		t.Errorf("expected frame 2, got %d", frameID)
	}

	frameID, ok = arc.Evict()
	if !ok || frameID != 3 {
		t.Errorf("expected frame 3, got %d", frameID)
	}

	if arc.Size() != 0 {
		t.Errorf("expected size 0, got %d", arc.Size())
	}
}

func TestARC_PinnedNotEvicted(t *testing.T) {
	arc := NewARC(3)

	arc.RecordAccess(1, 1)
	arc.RecordAccess(2, 2)
	arc.SetEvictable(1, false) // pinned
	arc.SetEvictable(2, true)

	// Size only counts evictable
	if arc.Size() != 1 {
		t.Errorf("expected size 1, got %d", arc.Size())
	}

	// Should evict frame 2, not frame 1
	frameID, ok := arc.Evict()
	if !ok || frameID != 2 {
		t.Errorf("expected frame 2, got %d", frameID)
	}

	// No more evictable frames
	_, ok = arc.Evict()
	if ok {
		t.Error("should not be able to evict pinned frame")
	}
}

func TestARC_PromoteToMFU(t *testing.T) {
	arc := NewARC(3)

	// First access - goes to T1 (MRU list)
	arc.RecordAccess(1, 1)
	arc.SetEvictable(1, true)

	// Second access - promotes to T2 (MFU list)
	arc.RecordAccess(1, 1)

	// Add another page to T1
	arc.RecordAccess(2, 2)
	arc.SetEvictable(2, true)

	// Evict should take from T1, not T2
	frameID, _ := arc.Evict()
	if frameID != 2 {
		t.Errorf("expected frame 2 from T1, got %d", frameID)
	}
}

func TestARC_GhostHitB1_IncreasesP(t *testing.T) {
	// Matches CMU test logic
	arc := NewARC(3)

	// Fill with 3 pages
	arc.RecordAccess(1, 1)
	arc.RecordAccess(2, 2)
	arc.RecordAccess(3, 3)
	arc.SetEvictable(1, true)
	arc.SetEvictable(2, true)
	arc.SetEvictable(3, true)
	// T1=[(1,f1), (2,f2), (3,f3)]

	// Evict all - they go to ghost B1
	arc.Evict() // evicts page 1
	arc.Evict() // evicts page 2
	arc.Evict() // evicts page 3
	// B1=[1, 2, 3], T1=[]

	// Access page 1 again on frame 3 - ghost hit in B1!
	// Should increase p and go to T2
	arc.RecordAccess(3, 1)
	arc.SetEvictable(3, true)

	// Access a new page 4 on frame 2
	arc.RecordAccess(2, 4)
	arc.SetEvictable(2, true)
	// T1=[(4,f2)], T2=[(1,f3)]

	// p increased to 1, T1 has 1 entry
	// Since |T1| (1) >= p (1), we evict from T1
	frameID, _ := arc.Evict()
	if frameID != 2 {
		t.Errorf("expected frame 2 (page 4 from T1), got %d", frameID)
	}
}

func TestARC_Remove(t *testing.T) {
	arc := NewARC(3)

	arc.RecordAccess(1, 1)
	arc.RecordAccess(2, 2)
	arc.SetEvictable(1, true)
	arc.SetEvictable(2, true)

	arc.Remove(1)

	if arc.Size() != 1 {
		t.Errorf("expected size 1, got %d", arc.Size())
	}

	frameID, _ := arc.Evict()
	if frameID != 2 {
		t.Errorf("expected frame 2, got %d", frameID)
	}
}

func TestARC_SampleTest(t *testing.T) {
	// Port of CMU's DISABLED_SampleTest
	arc := NewARC(7)

	// Add six frames, frame 6 is pinned
	arc.RecordAccess(1, 1)
	arc.RecordAccess(2, 2)
	arc.RecordAccess(3, 3)
	arc.RecordAccess(4, 4)
	arc.RecordAccess(5, 5)
	arc.RecordAccess(6, 6)
	arc.SetEvictable(1, true)
	arc.SetEvictable(2, true)
	arc.SetEvictable(3, true)
	arc.SetEvictable(4, true)
	arc.SetEvictable(5, true)
	arc.SetEvictable(6, false)

	if arc.Size() != 5 {
		t.Errorf("expected size 5, got %d", arc.Size())
	}

	// Access page 1 again - promotes to MFU
	arc.RecordAccess(1, 1)
	// T1=[(2,f2), (3,f3), (4,f4), (5,f5), p(6,f6)], T2=[(1,f1)]

	// Evict three pages from MRU (T1)
	frameID, _ := arc.Evict()
	if frameID != 2 {
		t.Errorf("expected frame 2, got %d", frameID)
	}
	frameID, _ = arc.Evict()
	if frameID != 3 {
		t.Errorf("expected frame 3, got %d", frameID)
	}
	frameID, _ = arc.Evict()
	if frameID != 4 {
		t.Errorf("expected frame 4, got %d", frameID)
	}

	if arc.Size() != 2 {
		t.Errorf("expected size 2, got %d", arc.Size())
	}
	// B1=[2,3,4], T1=[(5,f5), p(6,f6)], T2=[(1,f1)]

	// Insert new page 7 on frame 2 - NOT a ghost hit
	arc.RecordAccess(2, 7)
	arc.SetEvictable(2, true)

	// Insert page 2 on frame 3 - ghost hit in B1!
	// p should increase
	arc.RecordAccess(3, 2)
	arc.SetEvictable(3, true)
	// B1=[3,4], T1=[(5,f5), p(6,f6), (7,f2)], T2=[(2,f3), (1,f1)], p=1

	if arc.Size() != 4 {
		t.Errorf("expected size 4, got %d", arc.Size())
	}

	// Insert page 3 on frame 4 and page 4 on frame 7 (both ghost hits)
	arc.RecordAccess(4, 3)
	arc.SetEvictable(4, true)
	arc.RecordAccess(7, 4)
	arc.SetEvictable(7, true)
	// T1=[(5,f5), p(6,f6), (7,f2)], T2=[(4,f7), (3,f4), (2,f3), (1,f1)], p=3

	if arc.Size() != 6 {
		t.Errorf("expected size 6, got %d", arc.Size())
	}

	// Evict - |T1| evictable = 2 (5 and 7), p=3, so evict from T1
	frameID, _ = arc.Evict()
	if frameID != 5 {
		t.Errorf("expected frame 5, got %d", frameID)
	}
	// B1=[5], T1=[p(6,f6), (7,f2)], T2=[(4,f7), (3,f4), (2,f3), (1,f1)], p=3

	// Evict again - T1 evictable = 1, but p=3, so now evict from T2
	frameID, _ = arc.Evict()
	if frameID != 1 {
		t.Errorf("expected frame 1, got %d", frameID)
	}
	// B1=[5], T1=[p(6,f6), (7,f2)], T2=[(4,f7), (3,f4), (2,f3)], B2=[1], p=3

	// Access page 1 on frame 5 - ghost hit in B2! p decreases
	arc.RecordAccess(5, 1)
	arc.SetEvictable(5, true)
	// T1=[p(6,f6), (7,f2)], T2=[(1,f5), (4,f7), (3,f4), (2,f3)], p=2

	if arc.Size() != 5 {
		t.Errorf("expected size 5, got %d", arc.Size())
	}

	// Evict - p=2, T1 evictable=1 < p, so... actually evict from T1 since |T1|=1 < p=2
	// Wait, the test expects frame 2 (page 7)
	frameID, _ = arc.Evict()
	if frameID != 2 {
		t.Errorf("expected frame 2, got %d", frameID)
	}
}
