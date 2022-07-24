const std = @import("std");
const trait = std.meta.trait;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

const compact = @import("compact.zig");

// TODO test optionals

const PointerError = error{
    PointerNotInRange,
    SlicePointerInvalid,
};
const SealError = AllocatorError || PointerError;

// NOTE in this file, pointers that are the result of subtraction are
// incremented by 8 to keep them off the null location 0, while maintaining
// alignment to the largest primitive type.
// Perhaps a larger value might be valid here as well, to maintain alignment
// for even larger types?
pub fn seal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void {
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
                        return SealError.PointerNotInRange;
                    }
                },

                .Many => {
                    // NOTE there is no way to know how long the array is here. The user may know
                    // but there is no way to specify this.
                    @compileError("Cannot seal a multi target pointer!");
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
                    if (ptrLoc >= offset and (ptrLoc - offset) < size) {
                        ptr.*.ptr = @intToPtr([*]sliceElementType, ptrLoc - offset + 8);
                    } else {
                        return SealError.PointerNotInRange;
                    }
                },

                .C => {
                    // TODO if this was allowed, the structure would not be completely sealed. However,
                    // perhaps there is a use case for this, and it could be enabled by a flag?
                    // NOTE Similar to Many, there is no way to know how many items are present.
                    @compileError("Cannot seal a C pointer!");
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
            @compileError("Cannot seal a comptime int!");
        },

        .ComptimeFloat => {
            @compileError("Cannot seal a comptime float!");
        },

        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (compact.ComplexType(field.field_type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        @compileError("Cannot seal an untagged union with complex fields!");
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

        .Optional => |o| {
            if (compact.ComplexType(o.child)) {
                if (ptr.* != null) {
                    // I'm not sure about this- can we use a pointer to the inner part of an optional
                    // even if that optional is not a pointer?
                    try seal(*o.child, @ptrCast(*o.child, &ptr.*.?), offset, size);
                }
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

pub fn seal_into_buffer(comptime T: type, ptr: T, bytes: []u8) !void {
    var bufferAllocator = std.heap.FixedBufferAllocator.init(bytes);
    var allocator = bufferAllocator.allocator();

    // Move structure into buffer allocator area.
    var new_ptr = try compact.compact(T, ptr, allocator);
    try seal(T, new_ptr, @ptrToInt(bytes.ptr), bytes.len);
}

pub fn unseal_from_buffer(comptime T: type, bytes: []u8, allocator: Allocator) !T {
    var ptr = @ptrCast(T, @alignCast(@alignOf(T), bytes));
    try unseal(T, ptr, @ptrToInt(bytes.ptr), bytes.len);

    // Copy from buffer into given allocator.
    return try compact.compact(T, ptr, allocator);
}

pub fn unseal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    const ptrLoc = @ptrToInt(ptr.*);
                    if (ptrLoc >= 8 and (ptrLoc - 8) <= size) {
                        ptr.* = @intToPtr(child_type, offset + ptrLoc - 8);
                    } else {
                        return PointerError.PointerNotInRange;
                    }

                    try unseal(@Type(child), ptr.*, offset, size);
                },

                .Many => {
                    // NOTE there is no way to know how long the array is here. The user may know
                    // but there is no way to specify this.
                    @compileError("Cannot unseal a multi value pointer");
                },

                .Slice => {
                    const sliceElementType = @TypeOf(ptr.*[0]);

                    const ptrLoc = @ptrToInt(ptr.*.ptr);
                    if (ptrLoc >= 8 and (ptrLoc - 8) < size) {
                        ptr.*.ptr = @intToPtr([*]sliceElementType, offset + ptrLoc - 8);
                    } else {
                        return SealError.SlicePointerInvalid;
                    }

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
                    @compileError("Cannot unseal a C pointer");
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
            @compileError("Cannot unseal a comptime int");
        },

        .ComptimeFloat => {
            @compileError("Cannot unseal a comptime float");
        },

        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (compact.ComplexType(field.field_type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        @compileError("Cannot unseal an untagged union with complex fields");
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

        .Optional => |o| {
            if (compact.ComplexType(o.child)) {
                if (ptr.* != null) {
                    // I'm not sure about this- can we use a pointer to the inner part of an optional
                    // even if that optional is not a pointer?
                    try unseal(*o.child, @ptrCast(*o.child, &ptr.*.?), offset, size);
                }
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

test "seal relocate unseal" {
    const buffer_size = 1024;
    var buffer align(8) = [_]u8{0} ** buffer_size;
    var other_buffer align(8) = [_]u8{0} ** buffer_size;

    var bufferAllocator = std.heap.FixedBufferAllocator.init(buffer[0..]);
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

    try seal(*S2, ptr, @ptrToInt(&buffer[0]), buffer_size);
    try std.testing.expectEqual(@ptrToInt(ptr.*.a), @sizeOf(S2) + 8);

    // Convert packet to original value using the original pointer's location as the offset.
    try unseal(*S2, ptr, @ptrToInt(&buffer[0]), buffer_size);
    try std.testing.expectEqual(@ptrToInt(ptr), @ptrToInt(ptr));

    // Reseal structure.
    try seal(*S2, ptr, @ptrToInt(&buffer[0]), buffer_size);

    // Copy to a new location.
    std.mem.copy(u8, other_buffer[0..], buffer[0..]);

    // Unseal both locations so they can be compared.
    try unseal(*S2, ptr, @ptrToInt(&buffer[0]), buffer_size);

    var other_ptr = @ptrCast(*S2, @alignCast(8, &other_buffer[0]));
    try unseal(*S2, other_ptr, @ptrToInt(&other_buffer[0]), buffer_size);

    // Check that the old and new structures are the same.
    try std.testing.expectEqual(ptr.*.a.*, other_ptr.*.a.*);
    try std.testing.expectEqual(ptr.*.b[0].*, other_ptr.*.b[0].*);
    try std.testing.expectEqual(ptr.*.c.*, other_ptr.*.c.*);
}

test "seal and unseal with buffer" {
    const S1 = struct {
        a: u32,
        b: u8,
    };
    const S2 = struct { a: *u32, b: [1]*u8, c: *S1, d: []u16, e: ?*i8 };

    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();

    const buffer_size = 1024;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    var s2_ptr = try allocator.create(S2);
    defer allocator.destroy(s2_ptr);

    s2_ptr.a = try allocator.create(u32);
    defer allocator.destroy(s2_ptr.a);

    s2_ptr.b[0] = try allocator.create(u8);
    defer allocator.destroy(s2_ptr.b[0]);

    s2_ptr.c = try allocator.create(S1);
    defer allocator.destroy(s2_ptr.c);

    var slice_ptr = try allocator.create([2]u16);
    defer allocator.destroy(slice_ptr);
    s2_ptr.d = slice_ptr[0..];

    s2_ptr.e.? = try allocator.create(i8);
    defer allocator.destroy(s2_ptr.e.?);
    s2_ptr.e.?.* = 9;

    try seal_into_buffer(*S2, s2_ptr, buffer[0..]);

    var new_ptr = try unseal_from_buffer(*S2, buffer[0..], allocator);
    try std.testing.expectEqual(s2_ptr.*.a.*, new_ptr.*.a.*);
    try std.testing.expectEqual(s2_ptr.*.b[0].*, new_ptr.*.b[0].*);
    try std.testing.expectEqual(s2_ptr.*.c.*, new_ptr.*.c.*);

    try std.testing.expectEqual(s2_ptr.*.e.?.*, new_ptr.*.e.?.*);
}
