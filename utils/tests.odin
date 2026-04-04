package utils

import "core:testing"

@(test)
test_read_u16_le :: proc(t: ^testing.T) {
    data: [8]u8
    data[2] = 0xAB
    data[3] = 0xCD

    val, ok := read_u16_le(data[:], 2)
    testing.expect(t, ok, "read_u16_le should succeed")
    testing.expect_value(t, val, 0xCDAB)
}

@(test)
test_read_u32_le :: proc(t: ^testing.T) {
    data: [8]u8
    data[0] = 0x01
    data[1] = 0x00
    data[2] = 0x00
    data[3] = 0x00

    val, ok := read_u32_le(data[:], 0)
    testing.expect(t, ok, "read_u32_le should succeed")
    testing.expect_value(t, val, 1)
}

@(test)
test_read_u32_le_out_of_bounds :: proc(t: ^testing.T) {
    data: [4]u8

    _, ok := read_u32_le(data[:], 2)
    testing.expect(t, !ok, "read_u32_le should fail when out of bounds")
}

@(test)
test_write_u16_le :: proc(t: ^testing.T) {
    data: [8]u8

    write_ok := write_u16_le(data[:], 4, 0x1234)
    testing.expect(t, write_ok, "write_u16_le should succeed")

    val, read_ok := read_u16_le(data[:], 4)
    testing.expect(t, read_ok, "read_u16_le should succeed")
    testing.expect_value(t, val, 0x1234)
}

@(test)
test_write_u32_le :: proc(t: ^testing.T) {
    data: [8]u8

    write_ok := write_u32_le(data[:], 0, 42)
    testing.expect(t, write_ok, "write_u32_le should succeed")

    val, read_ok := read_u32_le(data[:], 0)
    testing.expect(t, read_ok, "read_u32_le should succeed")
    testing.expect_value(t, val, 42)
}

@(test)
test_write_u32_le_out_of_bounds :: proc(t: ^testing.T) {
    data: [4]u8

    ok := write_u32_le(data[:], 3, 99)
    testing.expect(t, !ok, "write_u32_le should fail when out of bounds")
}

@(test)
test_write_bytes :: proc(t: ^testing.T) {
    data: [8]u8
    src := [?]u8{0xAA, 0xBB, 0xCC}

    ok := write_bytes(data[:], 2, src[:])
    testing.expect(t, ok, "write_bytes should succeed")

    testing.expect_value(t, data[2], u8(0xAA))
    testing.expect_value(t, data[3], u8(0xBB))
    testing.expect_value(t, data[4], u8(0xCC))
}

@(test)
test_write_bytes_out_of_bounds :: proc(t: ^testing.T) {
    data: [4]u8
    src := [?]u8{0x01, 0x02, 0x03}

    ok := write_bytes(data[:], 3, src[:])
    testing.expect(t, !ok, "write_bytes should fail when out of bounds")
}
