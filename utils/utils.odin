package utils


read_val :: proc($T: typeid, data: []u8, offset: u32) -> (value: T, ok: bool) {
    if int(offset) + size_of(T) > len(data) {
        zero_val := T{}
        return zero_val, false
    }

    val := (cast(^T)&data[offset])^
    return val, true
}

write_val :: proc($T: typeid, data: []u8, offset: u32, value: T) -> bool {
    if int(offset) + size_of(T) > len(data) {
        return false
    }

    (cast(^T)&data[offset])^ = value
    return true
}

write_bytes :: proc(dest: []u8, offset: u32, src: []u8) -> bool {
    if int(offset) + len(src) > len(dest) {
        return false
    }

    copy(dest[offset:], src)
    return true
}