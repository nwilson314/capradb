package page

import "core:slice"
import "../utils"

/*
Header Layout (Total 12 Bytes):
0-3 (4 bytes): Page ID (uint32)
4-7 (4 bytes): LSN (uint32) - Log Sequence Number (last transaction that touched this page)
8-9 (2 bytes): FreeSpacePointer (uint16) - Points to the start of the data area (initially 4096).
10-11 (2 bytes): SlotCount (uint16) - Number of slots currently used.
Slot Layout (Total 4 Bytes):
0-1 (2 bytes): Offset (uint16)
2-3 (2 bytes): Length (uint16)
*/

/*
A deleted slot is marked as deleted by setting the length to 0.
*/


PAGE_SIZE :: 4096
HEADER_SIZE :: 12
SLOT_SIZE :: 4


Page :: struct {
    id: u32,
    data: [PAGE_SIZE]u8,
}

new_page :: proc(id: u32) -> ^Page {
    page := new(Page)

    page.id = id
    page.data = [PAGE_SIZE]u8{}

    utils.write_u32_le(page.data[:], 0, id)
    utils.write_u16_le(page.data[:], 8, PAGE_SIZE)

    return page
}

_get_free_space_ptr :: proc(page: ^Page) -> u16 {
    fsp, ok := utils.read_u16_le(page.data[:], 8)
    if !ok {
        return 0
    }
    return fsp
}

_get_slot_count :: proc(page: ^Page) -> u16 {
    sc, _ := utils.read_u16_le(page.data[:], 10)

    return sc
}

_get_free_space :: proc(page: ^Page) -> u16 {
    free_ptr := _get_free_space_ptr(page)
    slot_count := _get_slot_count(page)

    used_header := HEADER_SIZE + slot_count*SLOT_SIZE

    return free_ptr - used_header
}

// Returns:
// - pointer to data slot points to
// - length of that data
// - offset to the slot itself
_get_slot_data :: proc(page: ^Page, slot_id: u16) -> (u16, u16, u32) {
    slot_offset := u32(slot_id*SLOT_SIZE + HEADER_SIZE)
    data_offset, _ := utils.read_u16_le(page.data[:], slot_offset)
    data_len, _ := utils.read_u16_le(page.data[:], slot_offset + 2)
    return data_offset, data_len, slot_offset
}

insert_record :: proc(page: ^Page, data: []u8) -> bool {
    data_len := len(data)

    if data_len + SLOT_SIZE > int(_get_free_space_ptr(page)) {
        return false
    }

    // first check if there is a tombstoned slot that can be reused
    slot_spot: u16
    found := false
    for i in 0..<_get_slot_count(page) {
        _, slot_data_len, slot_offset := _get_slot_data(page, i)
        if slot_data_len == 0 {
            // found a tombstoned slot
            slot_spot = u16(i*SLOT_SIZE + HEADER_SIZE)
            found = true
            break
        }
    }

    if !found {
        slot_spot = _get_slot_count(page)*SLOT_SIZE + HEADER_SIZE
    }
    data_offset := int(_get_free_space_ptr(page)) - data_len

    // Insert slot information
    utils.write_u16_le(page.data[:], u32(slot_spot), u16(data_offset))
    utils.write_u16_le(page.data[:], u32(slot_spot + 2), u16(data_len))

    // Insert data
    utils.write_bytes(page.data[:], u32(data_offset), data[:])

    // Update free space pointer
    utils.write_u16_le(page.data[:], 8, u16(data_offset))

    // Update slot count if not reusing a tombstone
    if !found {
        utils.write_u16_le(page.data[:], 10, _get_slot_count(page) + 1)
    }

    return true
}

get_record :: proc(page: ^Page, slot_id: u16) -> ([]u8, bool) {
    if slot_id < 0 || slot_id >= _get_slot_count(page) {
        return nil, false
    }

    data_ptr, data_len, _ := _get_slot_data(page, slot_id)
    if data_len == 0 {
        return nil, false
    }

    return page.data[data_ptr:data_ptr+data_len], true
}

delete_record :: proc(page: ^Page, slot_id: u16) -> bool {
    if slot_id < 0 || slot_id >= _get_slot_count(page) {
        return false
    }

    _, data_len, slot_offset := _get_slot_data(page, slot_id)
    if data_len == 0 {
        // already deleted
        return false
    }

    utils.write_u16_le(page.data[:], u32(slot_offset + 2), 0)
    return true
}

update_record :: proc(page: ^Page, slot_id: u16, data: []u8) -> bool {
    if slot_id < 0 || slot_id >= _get_slot_count(page) {
        return false
    }

    update_len := len(data)
    data_offset, data_len, slot_offset := _get_slot_data(page, slot_id)
    if data_len == 0 {
        return false
    }

    if update_len <= int(data_len) {
        // update in place
        utils.write_bytes(page.data[:], u32(data_offset), data[:])
        // update slot length
        utils.write_u16_le(page.data[:], u32(slot_offset + 2), u16(update_len))
        return true
    }

    // data longer than existing, need to move data
    // currently, we don't have compaction logic

    if update_len > int(_get_free_space(page)) {
        // not enough space on page
        return false
    }

    // copy data to new offset
    new_data_offset := int(_get_free_space_ptr(page)) - update_len
    utils.write_bytes(page.data[:], u32(new_data_offset), data[:])
    // slot_offset
    utils.write_u16_le(page.data[:], u32(slot_offset), u16(new_data_offset))
    // update slot length
    utils.write_u16_le(page.data[:], u32(slot_offset + 2), u16(update_len))

    // move free space pointer
    utils.write_u16_le(page.data[:], 8, u16(new_data_offset))
    return true
}

SlotInfo :: struct {
    offset: u16,
    length: u16,
    slot_id: u16,
}

// Compacts the page by moving all data to the end of the page
compact_page :: proc(page: ^Page) -> bool {
    // first, collect all slot information and sort by offset
    num_slots := _get_slot_count(page)
    // allocate enough space for all slots
    slot_infos: [(PAGE_SIZE - HEADER_SIZE) / SLOT_SIZE]SlotInfo
    for i in 0..<num_slots {
        offset, length, _ := _get_slot_data(page, i)
        slot_infos[i] = SlotInfo{offset, length, u16(i)}
    }
    slice.sort_by(slot_infos[:], proc(a: SlotInfo, b: SlotInfo) -> bool {
        return a.offset > b.offset // sort by offset descending to get slots with highest offsets first
    })

    // Now, begin moving data to end of page
    // it is safe to blindly copy data as far "right" on the page as we want because
    // we sorted the slots by their offsets descending
    write_offset: u16 = PAGE_SIZE
    for &slot, i in slot_infos {
        if slot.length == 0 {
            // tombstone, so just skip
            continue
        }
        new_offset := write_offset - slot.length
        utils.write_bytes(page.data[:], u32(new_offset), page.data[slot.offset:slot.offset+slot.length])
        write_offset = new_offset

        // update slot information
        utils.write_u16_le(page.data[:], u32(slot.slot_id*SLOT_SIZE + HEADER_SIZE), new_offset)
        slot.offset = new_offset
    }

    // once we are done, update the free space pointer
    utils.write_u16_le(page.data[:], 8, write_offset)
    return true
}