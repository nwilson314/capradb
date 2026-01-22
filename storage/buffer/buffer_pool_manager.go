package buffer

import (
	"capradb/storage/disk"
	"capradb/storage/page"
	"capradb/storage/replacer"
	"fmt"
	"sync"
)

type BufferPoolManager struct {
	latch        sync.Mutex
	poolSize     uint32
	dm           *disk.DiskManager
	ds           *disk.DiskScheduler
	replacer     *replacer.ARC
	frames       []*page.Page
	pageToFrame  map[uint32]uint32 // pageID -> frameID
	frameHeaders []*FrameHeader
	emptyFrames  []uint32 // frameIDs list
}

type FrameHeader struct {
	latch    sync.RWMutex
	dirty    bool
	pinCount uint32
}

func NewBufferPoolManager(poolSize uint32, diskManager *disk.DiskManager, diskScheduler *disk.DiskScheduler) *BufferPoolManager {
	frames := make([]*page.Page, poolSize)
	frameHeaders := make([]*FrameHeader, poolSize)
	emptyFrames := make([]uint32, poolSize)

	for i := range poolSize {
		frameHeaders[i] = &FrameHeader{
			dirty:    false,
			pinCount: 0,
		}
		emptyFrames[i] = i
	}

	replacer := replacer.NewARC(poolSize)

	bpm := &BufferPoolManager{
		poolSize:     poolSize,
		dm:           diskManager,
		ds:           diskScheduler,
		replacer:     replacer,
		frames:       frames,
		pageToFrame:  make(map[uint32]uint32),
		frameHeaders: frameHeaders,
		emptyFrames:  emptyFrames,
	}
	return bpm
}

func (bpm *BufferPoolManager) GetPinCount(pageID uint32) (uint32, error) {
	bpm.latch.Lock()
	defer bpm.latch.Unlock()

	frameID, ok := bpm.pageToFrame[pageID]

	if !ok {
		return 0, fmt.Errorf("pageID not found")
	}

	frameHeader := bpm.frameHeaders[frameID]
	return frameHeader.pinCount, nil
}

func (bpm *BufferPoolManager) NewPage() (*WritePageGuard, error) {
	bpm.latch.Lock()

	frameID, err := bpm.getFrame()
	if err != nil {
		bpm.latch.Unlock()
		return nil, err
	}

	// create new page
	p := bpm.dm.AllocatePage()
	newPage := page.New(p)
	frameHeader := bpm.frameHeaders[frameID]
	bpm.frames[frameID] = newPage
	bpm.pageToFrame[p] = frameID
	frameHeader.dirty = true
	frameHeader.pinCount = 1
	bpm.replacer.RecordAccess(frameID, p)
	bpm.replacer.SetEvictable(frameID, false)
	bpm.latch.Unlock()
	frameHeader.latch.Lock()
	return &WritePageGuard{page: newPage, frame: frameHeader, bpm: bpm}, nil
}

func (bpm *BufferPoolManager) ReadPage(pageID uint32) (*ReadPageGuard, error) {
	bpm.latch.Lock()

	if frameID, ok := bpm.pageToFrame[pageID]; ok {
		frameHeader := bpm.frameHeaders[frameID]
		frameHeader.pinCount++
		bpm.replacer.RecordAccess(frameID, pageID)
		bpm.replacer.SetEvictable(frameID, false)
		bpm.latch.Unlock()
		frameHeader.latch.RLock()
		return &ReadPageGuard{page: bpm.frames[frameID], frame: frameHeader, bpm: bpm}, nil
	}

	frameID, err := bpm.getFrame()
	if err != nil {
		bpm.latch.Unlock()
		return nil, err
	}

	// read page from disk
	p, err := bpm.dm.ReadPage(pageID)
	if err != nil {
		bpm.latch.Unlock()
		return nil, err
	}

	bpm.frames[frameID] = p
	frameHeader := bpm.frameHeaders[frameID]
	bpm.pageToFrame[pageID] = frameID
	frameHeader.pinCount = 1
	frameHeader.dirty = false
	bpm.replacer.RecordAccess(frameID, pageID)
	bpm.replacer.SetEvictable(frameID, false)
	bpm.latch.Unlock()
	frameHeader.latch.RLock()
	return &ReadPageGuard{page: bpm.frames[frameID], frame: frameHeader, bpm: bpm}, nil
}

func (bpm *BufferPoolManager) WritePage(pageID uint32) (*WritePageGuard, error) {
	bpm.latch.Lock()

	if frameID, ok := bpm.pageToFrame[pageID]; ok {
		frameHeader := bpm.frameHeaders[frameID]
		frameHeader.pinCount++
		bpm.replacer.RecordAccess(frameID, pageID)
		bpm.replacer.SetEvictable(frameID, false)
		bpm.latch.Unlock()
		frameHeader.latch.Lock()
		return &WritePageGuard{page: bpm.frames[frameID], frame: frameHeader, bpm: bpm}, nil
	}

	frameID, err := bpm.getFrame()
	if err != nil {
		bpm.latch.Unlock()
		return nil, err
	}

	// read page from disk
	p, err := bpm.dm.ReadPage(pageID)
	if err != nil {
		bpm.latch.Unlock()
		return nil, err
	}

	bpm.frames[frameID] = p
	frameHeader := bpm.frameHeaders[frameID]
	bpm.pageToFrame[pageID] = frameID
	frameHeader.pinCount = 1
	frameHeader.dirty = false
	bpm.replacer.RecordAccess(frameID, pageID)
	bpm.replacer.SetEvictable(frameID, false)
	bpm.latch.Unlock()
	frameHeader.latch.Lock()
	return &WritePageGuard{page: bpm.frames[frameID], frame: frameHeader, bpm: bpm}, nil

}

func (bpm *BufferPoolManager) UnpinPage(pageID uint32, isDirty bool) bool {
	bpm.latch.Lock()
	defer bpm.latch.Unlock()

	frameID, ok := bpm.pageToFrame[pageID]
	if !ok {
		return false
	}

	frameHeader := bpm.frameHeaders[frameID]
	frameHeader.pinCount--
	if isDirty {
		frameHeader.dirty = true
	}
	if frameHeader.pinCount == 0 {
		bpm.replacer.SetEvictable(frameID, true)
	}
	return true
}

func (bpm *BufferPoolManager) FlushPage(pageID uint32) bool {
	bpm.latch.Lock()
	defer bpm.latch.Unlock()

	frameID, ok := bpm.pageToFrame[pageID]
	if !ok {
		return false
	}

	frameHeader := bpm.frameHeaders[frameID]
	if !frameHeader.dirty {
		// don't write page to disk if it's not dirty
		return false
	}

	err := bpm.dm.WritePage(bpm.frames[frameID])
	if err != nil {
		return false
	}
	frameHeader.dirty = false
	return true
}

func (bpm *BufferPoolManager) FlushAllPages() {
	bpm.latch.Lock()
	defer bpm.latch.Unlock()

	var requests []disk.DiskRequest
	var doneChans []chan bool

	for pageID, frameID := range bpm.pageToFrame {
		if bpm.frameHeaders[frameID].dirty {
			done := make(chan bool, 1)
			doneChans = append(doneChans, done)
			requests = append(requests, disk.DiskRequest{
				IsWrite: true,
				PageID:  pageID,
				Page:    bpm.frames[frameID],
				Done:    done,
			})
		}
	}

	bpm.ds.Schedule(requests)
	for _, done := range doneChans {
		<-done
	}

	for _, frameID := range bpm.pageToFrame {
		bpm.frameHeaders[frameID].dirty = false
	}
}

func (bpm *BufferPoolManager) DeletePage(pageID uint32) bool {
	bpm.latch.Lock()
	defer bpm.latch.Unlock()

	frameID, ok := bpm.pageToFrame[pageID]
	if !ok {
		return false
	}

	frameHeader := bpm.frameHeaders[frameID]
	if frameHeader.pinCount > 0 {
		return false
	}

	if bpm.frameHeaders[frameID].dirty {
		// write page to disk
		err := bpm.dm.WritePage(bpm.frames[frameID])
		if err != nil {
			return false
		}
	}
	delete(bpm.pageToFrame, pageID)
	bpm.frames[frameID] = nil
	bpm.emptyFrames = append(bpm.emptyFrames, frameID)
	bpm.replacer.Remove(frameID)
	return true
}

// helper function to get an empty frame for a page
// if no empty frames are available, evict one
func (bpm *BufferPoolManager) getFrame() (uint32, error) {
	emptyFrameLen := len(bpm.emptyFrames)
	if emptyFrameLen > 0 {
		frameID := bpm.emptyFrames[emptyFrameLen-1]
		bpm.emptyFrames = bpm.emptyFrames[:emptyFrameLen-1]
		return frameID, nil
	}

	// no empty frames in memory, so need to evict one
	frameID, ok := bpm.replacer.Evict()
	if !ok {
		return 0, fmt.Errorf("out of room in buffer and no frames are evictable")
	}

	if bpm.frameHeaders[frameID].dirty {
		// write page to disk
		err := bpm.dm.WritePage(bpm.frames[frameID])
		if err != nil {
			return 0, fmt.Errorf("failed to write page to disk: %v", err)
		}
	}
	oldPageID := bpm.frames[frameID].ID
	delete(bpm.pageToFrame, oldPageID)
	bpm.frames[frameID] = nil
	return frameID, nil
}
