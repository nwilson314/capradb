package disk

import "core:os"
import "core:testing"
import "../page"
import "../utils"

@(test)
test_allocate_page :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_allocate.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    defer free(dm)
    testing.expect(t, dm != nil, "disk manager should be created")

    // Allocate first page
    pg1 := allocate_page(dm)
    testing.expect_value(t, pg1.id, u32(1))
    testing.expect_value(t, dm.num_pages, u32(1))

    // Allocate second page
    pg2 := allocate_page(dm)
    testing.expect_value(t, pg2.id, u32(2))
    testing.expect_value(t, dm.num_pages, u32(2))

    // File should be 3 pages: metadata + 2 data pages
    file_size, _ := os.file_size(dm.file)
    testing.expect_value(t, file_size, i64(3 * page.PAGE_SIZE))
}

@(test)
test_write_and_read_page :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_write_read.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    defer free(dm)

    pg := allocate_page(dm)

    // Write some data into the page
    record := [?]u8{0xDE, 0xAD, 0xBE, 0xEF}
    page.insert_record(&pg, record[:])
    write_ok := write_page(dm, &pg)
    testing.expect(t, write_ok, "write should succeed")

    // Read it back
    read_pg, read_ok := read_page(dm, pg.id)
    testing.expect(t, read_ok, "read should succeed")

    // Verify the data survived the round trip
    data, get_ok := page.get_record(&read_pg, 0)
    testing.expect(t, get_ok, "get record should succeed after read")
    testing.expect_value(t, len(data), 4)
    testing.expect_value(t, data[0], u8(0xDE))
    testing.expect_value(t, data[1], u8(0xAD))
    testing.expect_value(t, data[2], u8(0xBE))
    testing.expect_value(t, data[3], u8(0xEF))
}

@(test)
test_reopen_existing_db :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_reopen.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    pg1 := allocate_page(dm)
    pg2 := allocate_page(dm)

    record := [?]u8{0xCA, 0xFE}
    page.insert_record(&pg2, record[:])
    write_page(dm, &pg2)
    close_disk_manager(dm)

    // Reopen: allocations and data must survive
    dm2 := new_disk_manager(path)
    defer close_disk_manager(dm2)
    testing.expect_value(t, dm2.num_pages, u32(2))

    read_pg, ok := read_page(dm2, pg2.id)
    testing.expect(t, ok, "read after reopen should succeed")
    data, get_ok := page.get_record(&read_pg, 0)
    testing.expect(t, get_ok, "get record after reopen should succeed")
    testing.expect_value(t, len(data), 2)
    testing.expect_value(t, data[0], u8(0xCA))
    testing.expect_value(t, data[1], u8(0xFE))

    // pg1 was allocated but never explicitly written; its id must still be valid
    _, ok1 := read_page(dm2, pg1.id)
    testing.expect(t, ok1, "allocated page should still be readable after reopen")
}

@(test)
test_write_page_invalid_id :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_write_invalid.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    defer free(dm)

    // Try to write a page that was never allocated
    fake_pg := page.new_page(99)
    defer free(fake_pg)
    ok := write_page(dm, fake_pg)
    testing.expect(t, !ok, "write to unallocated page should fail")
}

@(test)
test_read_page_invalid_id :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_read_invalid.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    defer free(dm)

    _, ok := read_page(dm, 99)
    testing.expect(t, !ok, "read of unallocated page should fail")
}

@(test)
test_write_read_multiple_pages :: proc(t: ^testing.T) {
    path := "/tmp/capradb_test_multi.db"
    defer os.remove(path)

    dm := new_disk_manager(path)
    defer free(dm)

    pg1 := allocate_page(dm)
    pg2 := allocate_page(dm)

    r1 := [?]u8{0xAA, 0xBB}
    r2 := [?]u8{0xCC, 0xDD, 0xEE}
    page.insert_record(&pg1, r1[:])
    page.insert_record(&pg2, r2[:])

    write_page(dm, &pg1)
    write_page(dm, &pg2)

    // Read back in reverse order
    read_pg2, ok2 := read_page(dm, pg2.id)
    testing.expect(t, ok2, "read page 2 should succeed")
    data2, _ := page.get_record(&read_pg2, 0)
    testing.expect_value(t, len(data2), 3)
    testing.expect_value(t, data2[0], u8(0xCC))

    read_pg1, ok1 := read_page(dm, pg1.id)
    testing.expect(t, ok1, "read page 1 should succeed")
    data1, _ := page.get_record(&read_pg1, 0)
    testing.expect_value(t, len(data1), 2)
    testing.expect_value(t, data1[0], u8(0xAA))
}
