const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Alignment = mem.Alignment;

pub const instance: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    _ = .{ ctx, len, ptr_align, ret_addr };
    return null;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = .{ ctx, buf, buf_align, new_len, ret_addr };
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = .{ ctx, memory, alignment, new_len, ret_addr };
    return null;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
    _ = .{ ctx, buf, buf_align, ret_addr };
}
