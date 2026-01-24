package buffer

import "capradb/storage/page"

type ReadPageGuard struct {
	page  *page.Page
	frame *FrameHeader
	bpm   *BufferPoolManager
}

type WritePageGuard struct {
	page  *page.Page
	frame *FrameHeader
	bpm   *BufferPoolManager
}

func (g *ReadPageGuard) Drop() {
	g.frame.latch.RUnlock()

	g.bpm.latch.Lock()
	g.frame.pinCount--
	if g.frame.pinCount == 0 {
		frameID := g.bpm.pageToFrame[g.page.ID]
		g.bpm.replacer.SetEvictable(frameID, true)
	}
	g.bpm.latch.Unlock()
}

func (g *WritePageGuard) Drop() {
	g.frame.dirty = true
	g.frame.latch.Unlock()

	g.bpm.latch.Lock()
	g.frame.pinCount--
	if g.frame.pinCount == 0 {
		frameID := g.bpm.pageToFrame[g.page.ID]
		g.bpm.replacer.SetEvictable(frameID, true)
	}
	g.bpm.latch.Unlock()
}

func (g *WritePageGuard) PageID() uint32 {
	return g.page.ID
}

func (g *WritePageGuard) InsertRecord(data []byte) (int, error) {
	return g.page.InsertRecord(data)
}

func (g *WritePageGuard) GetRecord(slotID int) ([]byte, error) {
	return g.page.GetRecord(slotID)
}

func (g *WritePageGuard) UpdateRecord(slotID int, data []byte) error {
	return g.page.UpdateRecord(slotID, data)
}

func (g *WritePageGuard) DeleteRecord(slotID int) error {
	return g.page.DeleteRecord(slotID)
}

func (g *WritePageGuard) GetFreeSpace() int {
	return g.page.GetFreeSpace()
}

func (g *ReadPageGuard) PageID() uint32 {
	return g.page.ID
}

func (g *ReadPageGuard) GetRecord(slotID int) ([]byte, error) {
	return g.page.GetRecord(slotID)
}

func (g *ReadPageGuard) GetSlotCount() uint16 {
	return g.page.GetSlotCount()
}
