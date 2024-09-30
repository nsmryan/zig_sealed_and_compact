const std = @import("std");
const trait = std.meta.trait;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

/// Check if a type is 'complex', meaning that it contains pointers or slices.
pub fn ComplexType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .Pointer => {
            return true;
        },

        .Array => |a| {
            return ComplexType(a.child);
        },

        .Struct => |s| {
            inline for (s.fields) |field| {
                if (ComplexType(field.type)) {
                    return true;
                }
            }
            return false;
        },

        .Union => |u| {
            inline for (u.fields) |field| {
                if (ComplexType(field.type)) {
                    return true;
                }
            }
            return false;
        },

        else => {
            return false;
        },
    }
}

/// Reallocate a structure given by the pointer 'value' into the given allocator.
/// This is a generic deep copy.
pub fn compact(comptime T: type, value: T, allocator: Allocator) AllocatorError!T {
    switch (@typeInfo(T)) {
        .Pointer => {
            return dupe(T, value, allocator);
        },

        else => {
            @compileError("Unable to compact non-pointer types! Expected a pointer to an allocation");
        },
    }
}

/// Repair a copied structure, meaning check for pointers and reallocate them in mutual
/// recursion with 'dupe'.
// NOTE I have no idea if this always works.
// For example, does it work on 0 length types? What about packed or extern types?
pub fn repair(comptime T: type, value_ptr: T, allocator: Allocator) AllocatorError!void {
    const child_type = @typeInfo(T).Pointer.child;
    const child = @typeInfo(child_type);
    switch (child) {
        .Pointer => |p| {
            switch (p.size) {
                .One => {
                    value_ptr.* = try dupe(@Type(child), value_ptr.*, allocator);
                },

                .Many => {
                    // NOTE there is no way to know how long the array is here. The user may know
                    // but there is no way to specify this.
                    @compileError("Unable to repair many valued pointer");
                },

                .Slice => {
                    const sliceElementType = @TypeOf(value_ptr.*[0]);
                    var duplicateSlice = try allocator.dupe(sliceElementType, @as([]const sliceElementType, @ptrCast(value_ptr.*)));

                    if (ComplexType(sliceElementType)) {
                        var index: usize = 0;
                        while (index < duplicateSlice.len) : (index += 1) {
                            try repair(@TypeOf(&duplicateSlice[index]), &duplicateSlice[index], allocator);
                        }
                    }

                    value_ptr.* = duplicateSlice;
                },

                .C => {
                    // TODO instead of panicing, perhaps just allow this? C structures are often managed
                    // specially anyway, and the user will just have to know that they are not copied?
                    // NOTE Similar to Many, there is no way to know how many items are present.
                    @compileError("Unable to repair C pointer");
                },
            }
        },

        .Struct => |s| {
            inline for (s.fields) |field| {
                const fieldPtr = &@field(value_ptr.*, field.name);
                try repair(@TypeOf(fieldPtr), fieldPtr, allocator);
            }
        },

        .ComptimeInt => {
            @compileError("Cannot repair a comptime int");
        },

        .ComptimeFloat => {
            @compileError("Cannot repair a comptime float");
        },

        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (ComplexType(field.type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        @compileError("Cannot repair an untagged union with complex fields!");
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(value_ptr.*), field.name)) {
                        const variant_ptr: *field.type = &@field(value_ptr.*, field.name);
                        try repair(@TypeOf(variant_ptr), variant_ptr, allocator);
                    }
                }
            }
        },

        .Optional => |o| {
            if (ComplexType(o.child)) {
                if (value_ptr.* != null) {
                    // I'm not sure about this- can we use a pointer to the inner part of an optional
                    // even if that optional is not a pointer?
                    try repair(*o.child, @as(*o.child, @ptrCast(&value_ptr.*)), allocator);
                }
            }
        },

        // NOTE this doesn't necessarily handle terminated arrays correctly.
        .Array => |a| {
            // If we have an array of complex underlying values, repair the underlying values.
            if (ComplexType(a.child)) {
                var index: usize = 0;
                while (index < a.len) : (index += 1) {
                    try repair(@TypeOf(&value_ptr[index]), &value_ptr[index], allocator);
                }
            }
        },

        // nothing to do.
        else => {},
    }
}

/// Duplicate an allocation using the given allocator, recusively reallocating and
/// updating pointers contained in the given object.
pub fn dupe(comptime T: type, value: T, allocator: Allocator) AllocatorError!T {
    const pointerInfo = @typeInfo(T).Pointer;
    const child = pointerInfo.child;
    const duplicateSlice = try allocator.dupe(child, @as([*]const child, @ptrCast(value))[0..1]);
    const duplicate = @as(T, @ptrCast(duplicateSlice));

    try repair(T, duplicate, allocator);

    return duplicate;
}

test "compact simple pointer" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *u32 = try allocator.create(u32);
    defer allocator.destroy(ptr);

    ptr.* = 0x01234567;
    const dupePtr = try compact(*u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*, dupePtr.*);
}

test "compact simple array" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *[3]u32 = try allocator.create([3]u32);
    defer allocator.destroy(ptr);

    ptr.*[0] = 1;
    ptr.*[1] = 2;
    ptr.*[2] = 3;
    const dupePtr = try compact(*[3]u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*[0], dupePtr.*[0]);
    try std.testing.expectEqual(ptr.*[1], dupePtr.*[1]);
    try std.testing.expectEqual(ptr.*[2], dupePtr.*[2]);
}

test "compact simple struct" {
    const S = struct { a: u64, b: u32, c: u8 };
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *S = try allocator.create(S);
    defer allocator.destroy(ptr);

    ptr.a = 1;
    ptr.b = 2;
    ptr.c = 3;
    const dupePtr = try compact(*S, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.a, dupePtr.a);
    try std.testing.expectEqual(ptr.b, dupePtr.b);
    try std.testing.expectEqual(ptr.c, dupePtr.c);
}

test "compact simple union" {
    const U = union(enum) { a: u64, b: u32, c: u8 };
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *U = try allocator.create(U);
    defer allocator.destroy(ptr);

    ptr.* = U{ .a = 1 };
    const dupePtr = try compact(*U, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.a, dupePtr.a);
}

test "compact union with string field" {
    const U = union(enum) { a: u64, b: u32, c: []const u8 };
    var heap_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heap_allocator.allocator();
    const ptr: *U = try allocator.create(U);
    defer allocator.destroy(ptr);

    ptr.* = U{ .c = "lorem ipsum" };
    const dupe_ptr = try compact(*U, ptr, allocator);
    try std.testing.expect(ptr != dupe_ptr);
    try std.testing.expectEqualStrings("lorem ipsum", dupe_ptr.c);
}

test "compact simple optional" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *?u32 = try allocator.create(?u32);
    defer allocator.destroy(ptr);

    ptr.* = 1;
    const dupePtr = try compact(*?u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*.?, dupePtr.*.?);

    ptr.* = null;
    const dupePtrNull = try compact(*?u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtrNull);
    try std.testing.expectEqual(ptr.*, dupePtrNull.*);
}

test "compact simple slice" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    const ptr: *[3]u32 = try allocator.create([3]u32);
    defer allocator.destroy(ptr);

    ptr.*[0] = 1;
    ptr.*[1] = 2;
    ptr.*[2] = 3;
    const dupePtr = try compact(*[3]u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expect(std.meta.eql(ptr.*, dupePtr.*));
    try std.testing.expectEqual(ptr.*[0], dupePtr.*[0]);
    try std.testing.expectEqual(ptr.*[1], dupePtr.*[1]);
    try std.testing.expectEqual(ptr.*[2], dupePtr.*[2]);
}

test "compact complex struct" {
    const S1 = struct { a: u64, b: u32, c: u8 };
    const S2 = struct {
        s1: *S1,
        s1_array: [3]S1,
        s1_array_ptrs: [3]*S1,
        s1_slice: []S1,
    };

    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();

    const ptr: *S2 = try allocator.create(S2);
    defer allocator.destroy(ptr);

    ptr.s1 = try allocator.create(S1);
    defer allocator.destroy(ptr.s1);

    ptr.s1.* = S1{ .a = 1, .b = 2, .c = 3 };
    ptr.s1_array = undefined;

    ptr.s1_array[0] = S1{ .a = 4, .b = 5, .c = 6 };
    ptr.s1_array[1] = S1{ .a = 7, .b = 8, .c = 9 };
    ptr.s1_array[2] = S1{ .a = 10, .b = 11, .c = 12 };

    ptr.s1_array_ptrs = undefined;

    ptr.s1_array_ptrs[0] = try allocator.create(S1);
    defer allocator.destroy(ptr.s1_array_ptrs[0]);

    ptr.s1_array_ptrs[1] = try allocator.create(S1);
    defer allocator.destroy(ptr.s1_array_ptrs[1]);

    ptr.s1_array_ptrs[2] = try allocator.create(S1);
    defer allocator.destroy(ptr.s1_array_ptrs[2]);

    ptr.s1_array_ptrs[0].* = ptr.s1_array[0];
    ptr.s1_array_ptrs[1].* = ptr.s1_array[1];
    ptr.s1_array_ptrs[2].* = ptr.s1_array[2];

    ptr.s1_slice = (try allocator.create([3]S1))[0..];
    defer allocator.free(ptr.s1_slice);
    ptr.s1_slice[0] = ptr.s1.*;
    ptr.s1_slice[1] = ptr.s1.*;
    ptr.s1_slice[2] = ptr.s1.*;

    const dupePtr = try compact(*S2, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expect(ptr.*.s1 != dupePtr.*.s1);
    try std.testing.expect(std.meta.eql(ptr.s1_array, dupePtr.s1_array));
    try std.testing.expect(std.meta.eql(ptr.s1_array_ptrs[0].*, dupePtr.s1_array_ptrs[0].*));
    try std.testing.expect(std.meta.eql(ptr.s1_array_ptrs[1].*, dupePtr.s1_array_ptrs[1].*));
    try std.testing.expect(std.meta.eql(ptr.s1_array_ptrs[2].*, dupePtr.s1_array_ptrs[2].*));
    try std.testing.expectEqual(ptr.s1_slice.len, dupePtr.s1_slice.len);
    try std.testing.expect(std.meta.eql(ptr.s1_slice[0], dupePtr.s1_slice[0]));
    try std.testing.expect(std.meta.eql(ptr.s1_slice[1], dupePtr.s1_slice[1]));
    try std.testing.expect(std.meta.eql(ptr.s1_slice[2], dupePtr.s1_slice[2]));
}
