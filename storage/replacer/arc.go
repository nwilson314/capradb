package replacer

import "container/list"

type ARC struct {
	c uint32
	p uint32
	// recent pages seen once
	t1 *list.List
	// frequent pages seen more than once
	t2 *list.List

	b1 *list.List
	b2 *list.List

	t1Index map[uint32]*list.Element
	t2Index map[uint32]*list.Element
	b1Index map[uint32]*list.Element
	b2Index map[uint32]*list.Element

	evictable map[uint32]bool

	frameToPage map[uint32]uint32
}

type Entry struct {
	frameID uint32
	pageID  uint32
}

func NewARC(c uint32) *ARC {
	a := &ARC{
		c:           c,
		p:           0,
		t1:          list.New(),
		t2:          list.New(),
		b1:          list.New(),
		b2:          list.New(),
		t1Index:     make(map[uint32]*list.Element),
		t2Index:     make(map[uint32]*list.Element),
		b1Index:     make(map[uint32]*list.Element),
		b2Index:     make(map[uint32]*list.Element),
		evictable:   make(map[uint32]bool),
		frameToPage: make(map[uint32]uint32),
	}

	return a
}

func (a *ARC) Size() int {
	count := 0

	for _, isEvictable := range a.evictable {
		if isEvictable {
			count++
		}
	}
	return count
}

func (a *ARC) RecordAccess(frameID uint32, pageID uint32) {
	// Case 1: Already in T1
	if el, ok := a.t1Index[pageID]; ok {
		// move to T2 MRU
		a.t2.PushFront(el.Value)
		a.t2Index[pageID] = a.t2.Front()
		a.t1.Remove(el)
		delete(a.t1Index, pageID)
		a.frameToPage[frameID] = pageID
		return
	}

	// Case 1: Already in T2
	if el, ok := a.t2Index[pageID]; ok {
		// move to T2 MRU
		a.t2.MoveToFront(el)
		a.t2Index[pageID] = a.t2.Front()
		a.frameToPage[frameID] = pageID
		return
	}

	// Case 2: Ghost hit in B1
	if el, ok := a.b1Index[pageID]; ok {
		a.p++
		a.b1.Remove(el)
		delete(a.b1Index, pageID)
		a.frameToPage[frameID] = pageID

		newEntry := Entry{
			frameID: frameID,
			pageID:  pageID,
		}
		a.t2.PushFront(newEntry)
		a.t2Index[pageID] = a.t2.Front()
		return
	}

	// Case 3: Ghost hit in B2
	if el, ok := a.b2Index[pageID]; ok {
		a.p--
		a.b2.Remove(el)
		delete(a.b2Index, pageID)
		a.frameToPage[frameID] = pageID

		newEntry := Entry{
			frameID: frameID,
			pageID:  pageID,
		}
		a.t2.PushFront(newEntry)
		a.t2Index[pageID] = a.t2.Front()
		return
	}

	// Case 4: Not found
	// Add to T1 -> first occurrence
	newEl := Entry{
		frameID: frameID,
		pageID:  pageID,
	}
	a.t1.PushFront(newEl)
	a.t1Index[pageID] = a.t1.Front()
	a.frameToPage[frameID] = pageID
}

func (a *ARC) SetEvictable(frameID uint32, evictable bool) {
	a.evictable[frameID] = evictable
}

func (a *ARC) Evict() (uint32, bool) {
	var lst *list.List
	var bLst *list.List
	var bIndex map[uint32]*list.Element
	if a.t1.Len() > 0 && uint32(a.t1.Len()) >= a.p {
		lst = a.t1
		bLst = a.b1
		bIndex = a.b1Index
	} else if a.t2.Len() > 0 {
		lst = a.t2
		bLst = a.b2
		bIndex = a.b2Index
	} else if a.t1.Len() > 0 {
		lst = a.t1
		bLst = a.b1
		bIndex = a.b1Index
	} else {
		// no valid lists to evict from
		return 0, false
	}

	for el := lst.Back(); el != nil; el = el.Prev() {
		entry := el.Value.(Entry)
		if a.evictable[entry.frameID] {
			lst.Remove(el)
			a.frameToPage[entry.frameID] = 0
			delete(a.t1Index, entry.pageID)
			delete(a.t2Index, entry.pageID)
			delete(a.evictable, entry.frameID)
			delete(a.frameToPage, entry.frameID)
			bLst.PushFront(entry)
			bIndex[entry.pageID] = bLst.Front()
			return entry.frameID, true
		}
	}

	return 0, false
}

func (a *ARC) Remove(frameID uint32) {
	pageID := a.frameToPage[frameID]

	if pageID == 0 {
		return
	}

	el, ok := a.t1Index[pageID]
	if ok {
		a.t1.Remove(el)
		a.t1Index[pageID] = nil
		a.frameToPage[frameID] = 0
		delete(a.evictable, frameID)
		delete(a.frameToPage, frameID)
		return
	}

	el, ok = a.t2Index[pageID]
	if ok {
		a.t2.Remove(el)
		a.t2Index[pageID] = nil
		a.frameToPage[frameID] = 0
		delete(a.evictable, frameID)
		delete(a.frameToPage, frameID)
		return
	}
}
