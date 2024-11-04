const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

const compact = @import("compact.zig");

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

/// Seal an object given by the pointer 'ptr'. The result will be that the structure is no
/// longer usable, but can be relocated, saved to disk, restored, and otherwise copied and
/// duplicated and then later 'unseal'ed to be usable again.
pub fn seal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    try seal(@Type(child), ptr.*, offset, size);

                    const ptrLoc = @intFromPtr(ptr.*);
                    if (ptrLoc >= offset and (ptrLoc - offset) < size) {
                        ptr.* = @ptrFromInt(ptrLoc - offset + 8);
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

                    const ptrLoc = @intFromPtr(ptr.*.ptr);
                    if (ptrLoc >= offset and (ptrLoc - offset) < size) {
                        @constCast(ptr).*.ptr = @ptrFromInt(ptrLoc - offset + 8);
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
                const fieldPtr = &@field(ptr.*, field.name);
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
                    if (compact.ComplexType(field.type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        @compileError("Cannot seal an untagged union with complex fields!");
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(ptr.*), field.name)) {
                        const variant_ptr: *field.type = @constCast(&@field(ptr.*, field.name));
                        try seal(@TypeOf(variant_ptr), variant_ptr, offset, size);
                    }
                }
            }
        },

        .Optional => |o| {
            if (compact.ComplexType(o.child)) {
                if (ptr.* != null) {
                    // I'm not sure about this- can we use a pointer to the inner part of an optional
                    // even if that optional is not a pointer?
                    try seal(*o.child, @as(*o.child, @constCast(@ptrCast(&ptr.*.?))), offset, size);
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

    try seal(**u32, &ptr, @intFromPtr(ptr), 1);
    try std.testing.expectEqual(@intFromPtr(ptr), 8);

    // Convert packet to original value using the original pointer's location as the offset.
    try unseal(**u32, &ptr, @intFromPtr(original_ptr), 8);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(original_ptr));
}

pub fn seal_into_buffer(comptime T: type, ptr: T, bytes: []u8) !usize {
    var bufferAllocator = std.heap.FixedBufferAllocator.init(bytes);
    const allocator = bufferAllocator.allocator();

    // Move structure into buffer allocator area.
    const new_ptr = try compact.compact(T, ptr, allocator);
    try seal(T, new_ptr, @intFromPtr(bytes.ptr), bytes.len);

    return bufferAllocator.end_index;
}

pub fn unseal_from_buffer(comptime T: type, bytes: []u8, allocator: Allocator) !T {
    const ptr = @as(T, @alignCast(@ptrCast(bytes)));
    try unseal(T, ptr, @intFromPtr(bytes.ptr), bytes.len);

    // Copy from buffer into given allocator.
    return try compact.compact(T, ptr, allocator);
}

/// Unseal a structure that was previously passed to 'seal. The structure will
/// be usable after the call to 'unseal' completes.
pub fn unseal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    const ptrLoc = @intFromPtr(ptr.*);
                    if (ptrLoc >= 8 and (ptrLoc - 8) <= size) {
                        ptr.* = @as(child_type, @ptrFromInt(offset + ptrLoc - 8));
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

                    const ptrLoc = @intFromPtr(ptr.*.ptr);
                    if (ptrLoc >= 8 and (ptrLoc - 8) < size) {
                        @constCast(ptr).*.ptr = @as([*]sliceElementType, @ptrFromInt(offset + ptrLoc - 8));
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
                const fieldPtr = &@field(ptr.*, field.name);
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
                    if (compact.ComplexType(field.type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        @compileError("Cannot unseal an untagged union with complex fields");
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(ptr.*), field.name)) {
                        const variant_ptr: *field.type = @constCast(&@field(ptr.*, field.name));
                        try unseal(@TypeOf(variant_ptr), variant_ptr, offset, size);
                    }
                }
            }
        },

        .Optional => |o| {
            if (compact.ComplexType(o.child)) {
                if (ptr.* != null) {
                    // I'm not sure about this- can we use a pointer to the inner part of an optional
                    // even if that optional is not a pointer?
                    try unseal(*o.child, @as(*o.child, @constCast(@ptrCast(&ptr.*.?))), offset, size);
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
    const ptr: *S2 = try allocator.create(S2);
    ptr.*.a = try allocator.create(u32);

    ptr.*.b[0] = try allocator.create(u8);

    ptr.*.c = try allocator.create(S1);
    ptr.*.c.a = 1;
    ptr.*.c.b = 2;

    try seal(*S2, ptr, @intFromPtr(&buffer[0]), buffer_size);
    try std.testing.expectEqual(@intFromPtr(ptr.*.a), @sizeOf(S2) + 8);

    // Convert packet to original value using the original pointer's location as the offset.
    try unseal(*S2, ptr, @intFromPtr(&buffer[0]), buffer_size);
    try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(ptr));

    // Reseal structure.
    try seal(*S2, ptr, @intFromPtr(&buffer[0]), buffer_size);

    // Copy to a new location.
    @memcpy(other_buffer[0..], buffer[0..]);

    // Unseal both locations so they can be compared.
    try unseal(*S2, ptr, @intFromPtr(&buffer[0]), buffer_size);

    const other_ptr = @as(*S2, @ptrCast(@alignCast(&other_buffer[0])));
    try unseal(*S2, other_ptr, @intFromPtr(&other_buffer[0]), buffer_size);

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

    _ = try seal_into_buffer(*S2, s2_ptr, buffer[0..]);

    const new_ptr = try unseal_from_buffer(*S2, buffer[0..], allocator);
    try std.testing.expectEqual(s2_ptr.*.a.*, new_ptr.*.a.*);
    try std.testing.expectEqual(s2_ptr.*.b[0].*, new_ptr.*.b[0].*);
    try std.testing.expectEqual(s2_ptr.*.c.*, new_ptr.*.c.*);

    try std.testing.expectEqual(s2_ptr.*.e.?.*, new_ptr.*.e.?.*);
}

test "seal and unseal union with string field with buffer" {
    const U = union(enum) { a: u64, b: []const u8, c: u32 };

    const buffer_size = 40;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    const allocator = std.testing.allocator;

    const u_ptr: *U = try allocator.create(U);

    u_ptr.* = U{ .b = "lorem ipsum" };
    _ = try seal_into_buffer(*U, u_ptr, buffer[0..]);

    // Make sure data exists only in the buffer
    allocator.destroy(u_ptr);

    const new_ptr = try unseal_from_buffer(*U, buffer[0..], allocator);
    defer {
        allocator.free(new_ptr.b);
        allocator.destroy(new_ptr);
    }

    // Make sure data exists only in the new_ptr
    inline for (&buffer) |*i| {
        i.* = 0;
    }

    try std.testing.expect(u_ptr != new_ptr);
    try std.testing.expectEqualStrings("lorem ipsum", new_ptr.b);
}

const E = enum { a, b, c };
test "seal and unseal structure with enum field with buffer" {
    const S = struct {
        a: E,
        b: u8,
    };

    const buffer_size = 2;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    const allocator = std.testing.allocator;

    var s_ptr = try allocator.create(S);

    s_ptr.a = E.c;
    s_ptr.b = 201;

    _ = try seal_into_buffer(*S, s_ptr, buffer[0..]);

    // Make sure data exists only in the buffer
    allocator.destroy(s_ptr);

    const new_ptr = try unseal_from_buffer(*S, buffer[0..], allocator);
    defer allocator.destroy(new_ptr);

    try std.testing.expectEqual(E.c, new_ptr.*.a);
    try std.testing.expectEqual(201, new_ptr.*.b);
}

test "seal and unseal structure with an optional slice of structures with buffer" {
    const S1 = struct {
        a: u32,
        b: u8,
    };
    const S2 = struct { a: u32, b: ?[]const S1 = null };

    const buffer_size = 40;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    const allocator = std.testing.allocator;

    var children = std.ArrayList(S1).init(allocator);
    defer children.deinit();

    try children.append(S1{
        .a = 4_294_967_295,
        .b = 'A',
    });

    var s2_ptr = try allocator.create(S2);

    s2_ptr.a = 2_147_483_647;
    s2_ptr.b = try children.toOwnedSlice();

    _ = try seal_into_buffer(*S2, s2_ptr, buffer[0..]);

    const child_ptr = &s2_ptr.b.?[0];
    // Make sure data exists only in the buffer
    allocator.free(s2_ptr.b.?);
    allocator.destroy(s2_ptr);

    const new_ptr = try unseal_from_buffer(*S2, buffer[0..], allocator);
    defer {
        allocator.free(new_ptr.b.?);
        allocator.destroy(new_ptr);
    }

    // Make sure data exists only in the new_ptr
    inline for (&buffer) |*i| {
        i.* = 0;
    }

    try std.testing.expectEqual(2_147_483_647, new_ptr.a);
    try std.testing.expect(child_ptr != &new_ptr.b.?[0]);
    try std.testing.expectEqual(4_294_967_295, new_ptr.b.?[0].a);
    try std.testing.expectEqual('A', new_ptr.b.?[0].b);
}

const R1 = struct {
    l: []const u8,
    children: ?[]const R1 = null,

    pub fn deinit(self: *const R1, allocator: std.mem.Allocator) void {
        const children = self.children orelse return;
        for (children) |*child| {
            child.deinit(allocator);
        }

        allocator.free(children);
    }

    pub fn deinitDeserialized(self: *const R1, allocator: std.mem.Allocator) void {
        allocator.free(self.l);

        const children = self.children orelse return;
        for (children) |*child| {
            child.deinitDeserialized(allocator);
        }

        allocator.free(children);
    }
};
test "seal and unseal recursive structure with buffer" {
    const buffer_size = 240;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    const allocator = std.testing.allocator;

    var children = std.ArrayList(R1).init(allocator);
    defer children.deinit();

    try children.append(R1{
        .l = "Leaf 1",
    });
    try children.append(R1{
        .l = "Leaf 2",
    });

    try children.append(R1{
        .l = "Branch 1",
        .children = try children.toOwnedSlice(),
    });

    try children.append(R1{
        .l = "Branch 2",
    });

    var r_ptr: *R1 = try allocator.create(R1);

    r_ptr.l = "Root";
    r_ptr.children = try children.toOwnedSlice();

    _ = try seal_into_buffer(*R1, r_ptr, buffer[0..]);

    // Make sure data exists only in the buffer
    r_ptr.deinit(allocator);
    allocator.destroy(r_ptr);

    const new_ptr: *R1 = try unseal_from_buffer(*R1, buffer[0..], allocator);
    defer {
        new_ptr.deinitDeserialized(allocator);
        allocator.destroy(new_ptr);
    }

    // Make sure data exists only in the new_ptr
    for (&buffer) |*i| {
        i.* = 0;
    }

    try std.testing.expectEqualStrings("Root", new_ptr.l);

    try std.testing.expectEqualStrings("Branch 1", new_ptr.children.?[0].l);
    try std.testing.expectEqualStrings("Leaf 1", new_ptr.children.?[0].children.?[0].l);
    try std.testing.expectEqualStrings("Leaf 2", new_ptr.children.?[0].children.?[1].l);

    try std.testing.expectEqualStrings("Branch 2", new_ptr.children.?[1].l);
    try std.testing.expectEqual(null, new_ptr.children.?[1].children);
}

const R2 = struct {
    l: []const u8,
    e: ?E = null,
    children: ?[]const C = null,

    pub fn deinit(self: *const R2, allocator: std.mem.Allocator) void {
        const children = self.children orelse return;
        for (children) |*child| {
            child.deinit(allocator);
        }

        allocator.free(children);
    }

    pub fn deinitDeserialized(self: *const R2, allocator: std.mem.Allocator) void {
        allocator.free(self.l);

        const children = self.children orelse return;
        for (children) |*child| {
            child.deinitDeserialized(allocator);
        }

        allocator.free(children);
    }
};

const C = union(enum) {
    s: []const u8,
    r: R2,

    pub fn deinit(self: C, allocator: std.mem.Allocator) void {
        switch (self) {
            C.r => self.r.deinit(allocator),
            else => undefined,
        }
    }

    pub fn deinitDeserialized(self: C, allocator: std.mem.Allocator) void {
        switch (self) {
            C.r => self.r.deinitDeserialized(allocator),
            C.s => allocator.free(self.s),
        }
    }
};
test "seal and unseal complex recursive union with buffer" {
    const buffer_size = 328;
    var buffer align(8) = [_]u8{0} ** buffer_size;

    const allocator = std.testing.allocator;

    var children = std.ArrayList(C).init(allocator);
    defer children.deinit();

    try children.append(C{ .s = "Leaf 1" });
    try children.append(C{ .s = "Leaf 2" });

    try children.append(C{
        .r = R2{
            .l = "Branch 1",
            .e = .a,
            .children = try children.toOwnedSlice(),
        },
    });
    try children.append(C{
        .r = R2{
            .l = "Branch 2",
            .e = .c,
        },
    });

    const c_ptr = try allocator.create(C);

    c_ptr.* = C{
        .r = R2{
            .l = "Root",
            .e = .b,
            .children = try children.toOwnedSlice(),
        },
    };

    _ = try seal_into_buffer(*C, c_ptr, buffer[0..]);

    c_ptr.deinit(allocator);
    allocator.destroy(c_ptr);

    const new_ptr: *C = try unseal_from_buffer(*C, buffer[0..], allocator);
    defer {
        new_ptr.deinitDeserialized(allocator);
        allocator.destroy(new_ptr);
    }

    // Make sure data exists only in the new_ptr
    inline for (&buffer) |*i| {
        i.* = 0;
    }

    try std.testing.expectEqualStrings("Root", new_ptr.r.l);
    try std.testing.expectEqual(.b, new_ptr.r.e);
    try std.testing.expectEqualStrings("Branch 1", new_ptr.r.children.?[0].r.l);
    try std.testing.expectEqual(.a, new_ptr.r.children.?[0].r.e);
    try std.testing.expectEqualStrings("Leaf 1", new_ptr.r.children.?[0].r.children.?[0].s);
    try std.testing.expectEqualStrings("Leaf 2", new_ptr.r.children.?[0].r.children.?[1].s);
    try std.testing.expectEqualStrings("Branch 2", new_ptr.r.children.?[1].r.l);
    try std.testing.expectEqual(.c, new_ptr.r.children.?[1].r.e);
}
