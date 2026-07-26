package disk

import "core:os"
import pg "../page"
import "../utils"

/*
    First page of the file is the metadata page.
    Layout:
    0-3 (4 bytes): num_pages (u32)
*/

DiskManager :: struct {
    file: ^os.File,
    num_pages: u32,
}

new_disk_manager :: proc(file_path: string) -> ^DiskManager {
    file_handle, err := os.open(file_path, os.O_RDWR | os.O_CREATE)
    if err != nil {
        return nil
    }

    dm := new(DiskManager)
    dm.file = file_handle
    dm.num_pages = 0

    file_size, _ := os.file_size(dm.file)
    if file_size >= i64(pg.PAGE_SIZE) {
        // existing database: load num_pages from the metadata page
        metadata: [pg.PAGE_SIZE]u8
        os.read_at(dm.file, metadata[:], 0)
        dm.num_pages, _ = utils.read_u32_le(metadata[:], 0)
    } else {
        _persist_metadata(dm)
    }

    return dm
}

_persist_metadata :: proc(dm: ^DiskManager) {
    metadata: [pg.PAGE_SIZE]u8
    utils.write_u32_le(metadata[:], 0, dm.num_pages)
    os.write_at(dm.file, metadata[:], 0)
}

close_disk_manager :: proc(dm: ^DiskManager) {
    os.close(dm.file)
    free(dm)
}


allocate_page :: proc(dm: ^DiskManager) -> pg.Page {
    dm.num_pages += 1
    _persist_metadata(dm)
    page := pg.new_page(dm.num_pages)
    defer free(page)
    page_offset := i64(dm.num_pages * pg.PAGE_SIZE)
    os.write_at(dm.file, page.data[:], page_offset)
    return page^
}

write_page :: proc(dm: ^DiskManager, page: ^pg.Page) -> bool {
    if page == nil {
        return false
    }

    if page.id > dm.num_pages {
        // page unallocated
        return false
    }

    page_offset := i64(page.id * pg.PAGE_SIZE)
    os.write_at(dm.file, page.data[:], page_offset)
    return true
}

read_page :: proc(dm: ^DiskManager, page_id: u32) -> (pg.Page, bool) {
    if page_id > dm.num_pages || page_id <= 0 {
        return pg.Page{}, false
    }

    page_offset := i64(page_id * pg.PAGE_SIZE)
    page := pg.Page{id = page_id}

    os.read_at(dm.file, page.data[:], page_offset)
    return page, true
}