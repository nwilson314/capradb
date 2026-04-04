package page

import "../utils"
import "core:testing"

@(test)
test_new_page :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    // Header fields
    id, id_ok := utils.read_u32_le(pg.data[:], 0)
    testing.expect(t, id_ok, "should read page ID")
    testing.expect_value(t, id, u32(1))

    lsn, lsn_ok := utils.read_u32_le(pg.data[:], 4)
    testing.expect(t, lsn_ok, "should read LSN")
    testing.expect_value(t, lsn, u32(0))

    fsp, fsp_ok := utils.read_u16_le(pg.data[:], 8)
    testing.expect(t, fsp_ok, "should read free space pointer")
    testing.expect_value(t, fsp, u16(PAGE_SIZE))

    slot_count, sc_ok := utils.read_u16_le(pg.data[:], 10)
    testing.expect(t, sc_ok, "should read slot count")
    testing.expect_value(t, slot_count, u16(0))
}

@(test)
test_insert_single_record :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    record := [?]u8{0xDE, 0xAD, 0xBE, 0xEF}
    ok := insert_record(pg, record[:])
    testing.expect(t, ok, "insert should succeed")

    // Slot count should be 1
    slot_count, _ := utils.read_u16_le(pg.data[:], 10)
    testing.expect_value(t, slot_count, u16(1))

    // Free space pointer should have moved down by 4 bytes
    fsp, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect_value(t, fsp, u16(PAGE_SIZE - 4))

    // Slot 0: offset should point to where data was written
    slot_offset, _ := utils.read_u16_le(pg.data[:], HEADER_SIZE)
    testing.expect_value(t, slot_offset, u16(PAGE_SIZE - 4))

    // Slot 0: length should be 4
    slot_len, _ := utils.read_u16_le(pg.data[:], HEADER_SIZE + 2)
    testing.expect_value(t, slot_len, u16(4))

    // Actual bytes at the end of the page
    testing.expect_value(t, pg.data[PAGE_SIZE - 4], u8(0xDE))
    testing.expect_value(t, pg.data[PAGE_SIZE - 3], u8(0xAD))
    testing.expect_value(t, pg.data[PAGE_SIZE - 2], u8(0xBE))
    testing.expect_value(t, pg.data[PAGE_SIZE - 1], u8(0xEF))
}

@(test)
test_insert_two_records :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA, 0xBB}
    r2 := [?]u8{0xCC, 0xDD, 0xEE}

    ok1 := insert_record(pg, r1[:])
    ok2 := insert_record(pg, r2[:])
    testing.expect(t, ok1, "first insert should succeed")
    testing.expect(t, ok2, "second insert should succeed")

    // Slot count should be 2
    slot_count, _ := utils.read_u16_le(pg.data[:], 10)
    testing.expect_value(t, slot_count, u16(2))

    // Free space pointer: 4096 - 2 - 3 = 4091
    fsp, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect_value(t, fsp, u16(4091))

    // First record bytes at 4094-4095
    testing.expect_value(t, pg.data[4094], u8(0xAA))
    testing.expect_value(t, pg.data[4095], u8(0xBB))

    // Second record bytes at 4091-4093
    testing.expect_value(t, pg.data[4091], u8(0xCC))
    testing.expect_value(t, pg.data[4092], u8(0xDD))
    testing.expect_value(t, pg.data[4093], u8(0xEE))
}

@(test)
test_insert_page_full :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    // Fill the page with records until it's full
    record: [512]u8
    inserted := 0
    for {
        ok := insert_record(pg, record[:])
        if !ok do break
        inserted += 1
    }

    // Should have inserted some but eventually failed
    testing.expect(t, inserted > 0, "should insert at least one record")
    testing.expect(t, inserted < 10, "should eventually run out of space")
}

@(test)
test_get_record :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xDE, 0xAD, 0xBE, 0xEF}
    r2 := [?]u8{0xCA, 0xFE}
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])

    // Get first record
    data1, ok1 := get_record(pg, 0)
    testing.expect(t, ok1, "get slot 0 should succeed")
    testing.expect_value(t, len(data1), 4)
    testing.expect_value(t, data1[0], u8(0xDE))
    testing.expect_value(t, data1[1], u8(0xAD))
    testing.expect_value(t, data1[2], u8(0xBE))
    testing.expect_value(t, data1[3], u8(0xEF))

    // Get second record
    data2, ok2 := get_record(pg, 1)
    testing.expect(t, ok2, "get slot 1 should succeed")
    testing.expect_value(t, len(data2), 2)
    testing.expect_value(t, data2[0], u8(0xCA))
    testing.expect_value(t, data2[1], u8(0xFE))

    // Out of bounds slot
    _, ok3 := get_record(pg, 5)
    testing.expect(t, !ok3, "get invalid slot should fail")
}

@(test)
test_delete_record :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA, 0xBB}
    r2 := [?]u8{0xCC, 0xDD}
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])

    // Delete slot 0
    ok := delete_record(pg, 0)
    testing.expect(t, ok, "delete should succeed")

    // Get on deleted slot should fail
    _, get_ok := get_record(pg, 0)
    testing.expect(t, !get_ok, "get on deleted record should fail")

    // Slot count should NOT change (tombstone, not removal)
    slot_count, _ := utils.read_u16_le(pg.data[:], 10)
    testing.expect_value(t, slot_count, u16(2))

    // Other record still accessible
    data2, ok2 := get_record(pg, 1)
    testing.expect(t, ok2, "get slot 1 should still work")
    testing.expect_value(t, data2[0], u8(0xCC))
    testing.expect_value(t, data2[1], u8(0xDD))
}

@(test)
test_delete_invalid_slot :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    ok := delete_record(pg, 0)
    testing.expect(t, !ok, "delete on empty page should fail")
}

@(test)
test_delete_already_deleted :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xFF}
    insert_record(pg, r[:])

    delete_record(pg, 0)
    ok := delete_record(pg, 0)
    testing.expect(t, !ok, "delete on already deleted record should fail")
}

@(test)
test_update_same_size :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xAA, 0xBB, 0xCC}
    insert_record(pg, r[:])

    fsp_before, _ := utils.read_u16_le(pg.data[:], 8)

    new_r := [?]u8{0x11, 0x22, 0x33}
    ok := update_record(pg, 0, new_r[:])
    testing.expect(t, ok, "update same size should succeed")

    // Data should be updated
    data, get_ok := get_record(pg, 0)
    testing.expect(t, get_ok, "get after update should succeed")
    testing.expect_value(t, data[0], u8(0x11))
    testing.expect_value(t, data[1], u8(0x22))
    testing.expect_value(t, data[2], u8(0x33))

    // Free space pointer should not move
    fsp_after, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect_value(t, fsp_after, fsp_before)
}

@(test)
test_update_smaller :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xAA, 0xBB, 0xCC, 0xDD}
    insert_record(pg, r[:])

    new_r := [?]u8{0x11, 0x22}
    ok := update_record(pg, 0, new_r[:])
    testing.expect(t, ok, "update smaller should succeed")

    // Should get back the shorter data
    data, get_ok := get_record(pg, 0)
    testing.expect(t, get_ok, "get after update should succeed")
    testing.expect_value(t, len(data), 2)
    testing.expect_value(t, data[0], u8(0x11))
    testing.expect_value(t, data[1], u8(0x22))
}

@(test)
test_update_bigger :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xAA, 0xBB}
    insert_record(pg, r[:])

    fsp_before, _ := utils.read_u16_le(pg.data[:], 8)

    new_r := [?]u8{0x11, 0x22, 0x33, 0x44, 0x55}
    ok := update_record(pg, 0, new_r[:])
    testing.expect(t, ok, "update bigger should succeed")

    // Should get back the new data
    data, get_ok := get_record(pg, 0)
    testing.expect(t, get_ok, "get after update should succeed")
    testing.expect_value(t, len(data), 5)
    testing.expect_value(t, data[0], u8(0x11))
    testing.expect_value(t, data[4], u8(0x55))

    // Free space pointer should have moved down (old space wasted + new space allocated)
    fsp_after, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect(t, fsp_after < fsp_before, "fsp should move down for bigger record")
}

@(test)
test_update_invalid_slot :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xAA}
    ok := update_record(pg, 0, r[:])
    testing.expect(t, !ok, "update on empty page should fail")
}

@(test)
test_update_deleted_slot :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r := [?]u8{0xAA}
    insert_record(pg, r[:])
    delete_record(pg, 0)

    new_r := [?]u8{0xBB}
    ok := update_record(pg, 0, new_r[:])
    testing.expect(t, !ok, "update on deleted record should fail")
}

@(test)
test_insert_reuses_tombstone :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA, 0xBB}
    r2 := [?]u8{0xCC, 0xDD}
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])

    // Delete slot 0
    delete_record(pg, 0)

    // Slot count is 2
    sc_before, _ := utils.read_u16_le(pg.data[:], 10)
    testing.expect_value(t, sc_before, u16(2))

    // Insert new record — should reuse slot 0
    r3 := [?]u8{0xEE, 0xFF}
    insert_record(pg, r3[:])

    // Slot count should still be 2
    sc_after, _ := utils.read_u16_le(pg.data[:], 10)
    testing.expect_value(t, sc_after, u16(2))

    // Slot 0 should have the new data
    data, ok := get_record(pg, 0)
    testing.expect(t, ok, "get reused slot should succeed")
    testing.expect_value(t, data[0], u8(0xEE))
    testing.expect_value(t, data[1], u8(0xFF))

    // Slot 1 should be untouched
    data2, ok2 := get_record(pg, 1)
    testing.expect(t, ok2, "get slot 1 should still work")
    testing.expect_value(t, data2[0], u8(0xCC))
    testing.expect_value(t, data2[1], u8(0xDD))
}

@(test)
test_compact_reclaims_deleted_space :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA, 0xBB, 0xCC} // 3 bytes
    r2 := [?]u8{0xDD, 0xEE}        // 2 bytes
    r3 := [?]u8{0x11, 0x22, 0x33}  // 3 bytes
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])
    insert_record(pg, r3[:])

    // Delete middle record
    delete_record(pg, 1)

    fsp_before, _ := utils.read_u16_le(pg.data[:], 8)

    compact_page(pg)

    // Free space pointer should move up (reclaimed 2 bytes from deleted record)
    fsp_after, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect(t, fsp_after > fsp_before, "fsp should move up after compaction")

    // Surviving records should still be readable with correct data
    data0, ok0 := get_record(pg, 0)
    testing.expect(t, ok0, "slot 0 should still be readable")
    testing.expect_value(t, len(data0), 3)
    testing.expect_value(t, data0[0], u8(0xAA))
    testing.expect_value(t, data0[1], u8(0xBB))
    testing.expect_value(t, data0[2], u8(0xCC))

    data2, ok2 := get_record(pg, 2)
    testing.expect(t, ok2, "slot 2 should still be readable")
    testing.expect_value(t, len(data2), 3)
    testing.expect_value(t, data2[0], u8(0x11))
    testing.expect_value(t, data2[1], u8(0x22))
    testing.expect_value(t, data2[2], u8(0x33))

    // Deleted slot should still be a tombstone
    _, ok1 := get_record(pg, 1)
    testing.expect(t, !ok1, "deleted slot should still be dead")
}

@(test)
test_compact_after_update_bigger :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA, 0xBB}       // 2 bytes
    r2 := [?]u8{0xCC}              // 1 byte
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])

    // Update slot 0 with bigger data — old 2 bytes become dead space
    new_r := [?]u8{0x11, 0x22, 0x33, 0x44}
    update_record(pg, 0, new_r[:])

    fsp_before, _ := utils.read_u16_le(pg.data[:], 8)

    compact_page(pg)

    // Should reclaim the old 2 bytes of dead space
    fsp_after, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect(t, fsp_after > fsp_before, "fsp should move up after compaction")

    // Both records should still be correct
    data0, ok0 := get_record(pg, 0)
    testing.expect(t, ok0, "slot 0 should be readable")
    testing.expect_value(t, len(data0), 4)
    testing.expect_value(t, data0[0], u8(0x11))
    testing.expect_value(t, data0[3], u8(0x44))

    data1, ok1 := get_record(pg, 1)
    testing.expect(t, ok1, "slot 1 should be readable")
    testing.expect_value(t, data1[0], u8(0xCC))
}

@(test)
test_compact_no_dead_space :: proc(t: ^testing.T) {
    pg := new_page(1)
    defer free(pg)

    r1 := [?]u8{0xAA}
    r2 := [?]u8{0xBB}
    insert_record(pg, r1[:])
    insert_record(pg, r2[:])

    fsp_before, _ := utils.read_u16_le(pg.data[:], 8)

    compact_page(pg)

    // Nothing to reclaim — fsp should stay the same
    fsp_after, _ := utils.read_u16_le(pg.data[:], 8)
    testing.expect_value(t, fsp_after, fsp_before)

    // Data still correct
    data0, _ := get_record(pg, 0)
    testing.expect_value(t, data0[0], u8(0xAA))
    data1, _ := get_record(pg, 1)
    testing.expect_value(t, data1[0], u8(0xBB))
}
