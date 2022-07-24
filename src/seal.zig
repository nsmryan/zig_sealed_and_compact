const std = @import("std");
const trait = std.meta.trait;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

const compact = @import("compact.zig");

// TODO implement 'seal' and 'unseal' functions:
// take a pointer initially, and then recurse using that base
// pointer as the relative offset. This seems like the best design.
// Kind of assumes that the base pointer is first in memory. This is
// true with compact and a bump allocator, but not necessarily otherwise.
// Another option is an allocator's base pointer, and then you can seal
// any pointers within, in place. You can then move the whole allocation
// space. This requires some care, but seems like it would work.
//
//
// unseal takes the same arguments, but reverses the process.
//
// Together these allow memory to become relocatable, to be moved,
// and then to become usable again.
//
// Consider taking a pointer, wrapping it in a Sealed struct,
// with an unseal function that returns the original pointer or
// something similar to make it clear that the pointer should not be
// used.
//
// May take a byte array and create a dump allocator out of it, then use
// compact to copy into this array, returning the used bytes or a slice
// to those bytes. This allows the user to give their desired block of
// memory.
//
// On unseal, could either occur in place, or unseal and then compact into another
// allocator?

pub fn seal(comptime T: type, ptr: T, offset: usize, size: usize) !void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    try seal(@Type(child), ptr.*, offset, size);

                    const ptrLoc = @ptrToInt(ptr.*);
                    if (ptrLoc >= offset and (ptrLoc - offset) < size) {
                        ptr.* = @intToPtr(child_type, ptrLoc - offset + 8);
                    } else {
                        // TODO return an error in a SealError set.
                    }
                },

                .Many => {
                    // NOTE there is no way to know how long the array is here. The user may know
                    // but there is no way to specify this.
                    unreachable;
                },

                .Slice => {
                    const sliceElementType = @TypeOf(ptr.*[0]);
                    if (compact.ComplexType(sliceElementType)) {
                        var index: usize = 0;
                        while (index < ptr.*.len) : (index += 1) {
                            try seal(@TypeOf(&ptr.*[index]), &ptr.*[index], offset, size);
                        }
                    }

                    const ptrLoc = @ptrToInt(ptr.*.ptr);
                    if (ptrLoc >= offset and (offset - ptrLoc) < size) {
                        ptr.*.ptr = @intToPtr(child_type, offset - ptrLoc + 8);
                    } else {
                        // TODO return an error in a SealError set.
                    }
                },

                .C => {
                    // TODO if this was allowed, the structure would not be completely sealed. However,
                    // perhaps there is a use case for this, and it could be enabled by a flag?
                    // NOTE Similar to Many, there is no way to know how many items are present.
                    unreachable;
                },
            }
        },

        .Struct => |s| {
            inline for (s.fields) |field| {
                var fieldPtr = &@field(ptr.*, field.name);
                try seal(@TypeOf(fieldPtr), fieldPtr, offset, size);
            }
        },

        .ComptimeInt => {
            unreachable;
        },

        .ComptimeFloat => {
            unreachable;
        },

        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (compact.ComplexType(field.field_type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        unreachable;
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(ptr.*), field.name)) {
                        const variantPtr: *field.field_type = undefined;
                        try seal(@TypeOf(variantPtr), variantPtr, offset, size);
                    }
                }
            }
        },

        .Optional => {
            if (ptr.*) |inner| {
                try seal(@TypeOf(&inner), &inner, offset, size);
                ptr.* = inner;
            }
        },

        // NOTE this doesn't necessarily handle terminated arrays correctly.
        .Array => |a| {
            if (compact.ComplexType(a.child)) {
                var index: usize = 0;
                while (index < a.len) : (index += 1) {
                    try seal(@TypeOf(&ptr[index]), &ptr[index], offset, size);
                }
            }
        },

        // nothing to do.
        else => {},
    }
}

test "seal simple pointer" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *u32 = try allocator.create(u32);
    const original_ptr = ptr;
    defer allocator.destroy(original_ptr);

    try seal(**u32, &ptr, @ptrToInt(ptr), 1);
    try std.testing.expectEqual(@ptrToInt(ptr), 8);

    // Convert packet to original value using the original pointer's location as the offset.
    try unseal(**u32, &ptr, @ptrToInt(original_ptr), 8);
    try std.testing.expectEqual(@ptrToInt(ptr), @ptrToInt(original_ptr));
}

test "seal relocate unseal" {
    const buffer_size = 1024;
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var mainAllocator = heapAllocator.allocator();
    var buffer = try mainAllocator.create([buffer_size]u8);
    defer mainAllocator.destroy(buffer);

    var other_buffer = try mainAllocator.create([buffer_size]u8);
    defer mainAllocator.destroy(other_buffer);

    var bufferAllocator = std.heap.FixedBufferAllocator.init(buffer);
    var allocator = bufferAllocator.allocator();

    const S1 = struct {
        a: u32,
        b: u8,
    };
    const S2 = struct { a: *u32, b: [1]*u8, c: *S1 };
    var ptr: *S2 = try allocator.create(S2);
    ptr.*.a = try allocator.create(u32);

    ptr.*.b[0] = try allocator.create(u8);

    ptr.*.c = try allocator.create(S1);
    ptr.*.c.a = 1;
    ptr.*.c.b = 2;

    try seal(*S2, ptr, @ptrToInt(buffer), buffer_size);
    try std.testing.expectEqual(@ptrToInt(ptr.*.a), @sizeOf(S2) + 8);

    // Convert packet to original value using the original pointer's location as the offset.
    try unseal(*S2, ptr, @ptrToInt(buffer), buffer_size);
    try std.testing.expectEqual(@ptrToInt(ptr), @ptrToInt(ptr));

    // Reseal structure
    try seal(*S2, ptr, @ptrToInt(buffer), buffer_size);
    // copy to a new location
    std.mem.copy(u8, other_buffer, buffer);
    // unseal at the new location.
    var other_ptr = @ptrCast(*S2, @alignCast(8, other_buffer));

    try unseal(*S2, ptr, @ptrToInt(buffer), buffer_size);
    try unseal(*S2, other_ptr, @ptrToInt(other_buffer), buffer_size);

    // check that the old and new structures are the same.
    try std.testing.expectEqual(ptr.*.a.*, other_ptr.*.a.*);
    try std.testing.expectEqual(ptr.*.b[0].*, other_ptr.*.b[0].*);
    try std.testing.expectEqual(ptr.*.c.*, other_ptr.*.c.*);
}

//pub fn seal_alloc(comptime T: type, ptr: T, allocator: Allocator) !void {
//    // TODO recurse on structure of
//}

//pub fn seal_into_buffer(comptime T: type, ptr: T, bytes: []u8) !void {
//}

pub fn unseal(comptime T: type, ptr: T, offset: usize, size: usize) !void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    const ptrLoc = @ptrToInt(ptr.*);
                    if (ptrLoc >= 8 and (ptrLoc - 8 + @sizeOf(child_type)) <= size) {
                        ptr.* = @intToPtr(child_type, offset + ptrLoc - 8);
                    } else {
                        // TODO return an error in a SealError set.
                    }

                    try unseal(@Type(child), ptr.*, offset, size);
                },

                .Many => {
                    // NOTE there is no way to know how long the array is here. The user may know
                    // but there is no way to specify this.
                    unreachable;
                },

                .Slice => {
                    const ptrLoc = @ptrToInt(ptr.*.ptr);
                    if (ptrLoc >= 8 and (ptrLoc - 8 + @sizeOf(child_type)) < size) {
                        ptr.*.ptr = @intToPtr(child_type, offset + ptrLoc - 8);
                    } else {
                        // TODO return an error in a SealError set.
                    }

                    const sliceElementType = @TypeOf(ptr.*[0]);
                    if (compact.ComplexType(sliceElementType)) {
                        var index: usize = 0;
                        while (index < ptr.*.len) : (index += 1) {
                            try unseal(@TypeOf(&ptr.*[index]), &ptr.*[index], offset, size);
                        }
                    }
                },

                .C => {
                    // No way to unseal a C pointer unless we assume it was allocated by a Zig allocator,
                    // which is not particularly likely.
                    unreachable;
                },
            }
        },

        .Struct => |s| {
            inline for (s.fields) |field| {
                var fieldPtr = &@field(ptr.*, field.name);
                try unseal(@TypeOf(fieldPtr), fieldPtr, offset, size);
            }
        },

        .ComptimeInt => {
            unreachable;
        },

        .ComptimeFloat => {
            unreachable;
        },

        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (compact.ComplexType(field.field_type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        unreachable;
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(ptr.*), field.name)) {
                        const variantPtr: *field.field_type = undefined;
                        try unseal(@TypeOf(variantPtr), variantPtr, offset, size);
                    }
                }
            }
        },

        .Optional => {
            if (ptr.*) |inner| {
                try unseal(@TypeOf(&inner), &inner, offset, size);
                // TODO replace with sealed pointer
            }
        },

        // NOTE this doesn't necessarily handle terminated arrays correctly.
        .Array => |a| {
            if (compact.ComplexType(a.child)) {
                var index: usize = 0;
                while (index < a.len) : (index += 1) {
                    try unseal(@TypeOf(&ptr[index]), &ptr[index], offset, size);
                }
            }
        },

        // nothing to do.
        else => {},
    }
}
