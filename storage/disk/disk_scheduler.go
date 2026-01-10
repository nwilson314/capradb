package disk

import "capradb/storage/page"

type DiskScheduler struct {
	dm       *DiskManager
	requests chan DiskRequest
	done     chan struct{}
}

type DiskRequest struct {
	IsWrite bool
	PageID  uint32
	Page    *page.Page
	Done    chan bool
}

func NewDiskScheduler(diskManager *DiskManager) *DiskScheduler {
	ds := &DiskScheduler{
		dm:       diskManager,
		requests: make(chan DiskRequest),
		done:     make(chan struct{}),
	}
	go ds.run()
	return ds
}

func (ds *DiskScheduler) Shutdown() {
	close(ds.done)
	close(ds.requests)
}

func (ds *DiskScheduler) Schedule(requests []DiskRequest) {
	for _, request := range requests {
		ds.requests <- request
	}
}

func (ds *DiskScheduler) run() {
	for {
		select {
		case req := <-ds.requests:
			if req.IsWrite {
				err := ds.dm.WritePage(req.Page)
				if err != nil {
					req.Done <- false
					continue
				}
			} else {
				p, err := ds.dm.ReadPage(req.PageID)
				if err != nil {
					req.Done <- false
					continue
				}
				copy(req.Page.Data[:], p.Data[:])
			}
			req.Done <- true
		case <-ds.done:
			return
		}
	}
}
