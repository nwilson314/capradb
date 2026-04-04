package utils

import "core:encoding/endian"

read_u16_le :: proc(data: []u8, offset: u32) -> (value: u16, ok: bool) {
    if int(offset) + 2 > len(data) {
        return 0, false
    }
    return endian.get_u16(data[offset:], .Little)
}

read_u32_le :: proc(data: []u8, offset: u32) -> (value: u32, ok: bool) {
    if int(offset) + 4 > len(data) {
        return 0, false
    }
    return endian.get_u32(data[offset:], .Little)
}

write_u16_le :: proc(data: []u8, offset: u32, value: u16) -> bool {
    if int(offset) + 2 > len(data) {
        return false
    }
    return endian.put_u16(data[offset:], .Little, value)
}

write_u32_le :: proc(data: []u8, offset: u32, value: u32) -> bool {
    if int(offset) + 4 > len(data) {
        return false
    }
    return endian.put_u32(data[offset:], .Little, value)
}

write_bytes :: proc(dest: []u8, offset: u32, src: []u8) -> bool {
    if int(offset) + len(src) > len(dest) {
        return false
    }

    copy(dest[offset:], src)
    return true
}