const std = @import("std");
const trait = std.meta.trait;
const testing = std.testing;
const Allocator = std.mem.Allocator;

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
                if (ComplexType(field.field_type)) {
                    return true;
                }
            }
            return false;
        },

        .Union => |u| {
            inline for (u.fields) |field| {
                if (ComplexType(field.field_type)) {
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

pub fn compact(comptime T: type, value: T, allocator: Allocator) !T {
    switch (@typeInfo(T)) {
        .Pointer => |p| {
            return dupe(T, value, p.child, allocator);
        },

        else => {
            unreachable;
        },
    }
}

// NOTE I have no idea if this always works. For example, does it work on 0 length types?
pub fn repair(comptime T: type, value: T, comptime Child: type, allocator: Allocator) void {
    switch (@typeInfo(Child)) {
        .Pointer => |p| {
            value.* = dupe(T, value, @Type(p.child), allocator);
        },

        .Struct => |s| {
            inline for (s.fields) |field| {
                var fieldPtr = &@field(value.*, field.name);
                repair(@TypeOf(fieldPtr), fieldPtr, field.field_type, allocator);
            }
        },

        .ComptimeInt => {
            unreachable;
        },

        .ComptimeFloat => {
            unreachable;
        },

        // Hopefully this results in a void return.
        .Void => return,

        .Union => |u| {
            if (u.tag_type == null) {
                inline for (u.fields) |field| {
                    if (ComplexType(field.field_type)) {
                        // TODO compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                    }
                }
            } else {
                inline for (u.fields) |field| {
                    // Compare name to find variant in field list
                    if (std.mem.eql(u8, @tagName(value.*), field.name)) {
                        // TODO this may be a problem if we actually allocate this structure on the stack.
                        // However, I don't know how else to synthesis a pointer type from a type.
                        const variant: field.field_type = undefined;
                        var variantPtr = @ptrCast(@TypeOf(&variant), value);
                        repair(@TypeOf(variantPtr), variantPtr, field.field_type, allocator);
                    }
                }
            }
        },

        .Optional => {
            if (value.*) |child| {
                repair(@TypeOf(&child), &child, @TypeOf(child), allocator);
            }
        },

        // NOTE this doesn't necessarily handle terminated arrays correctly.
        .Array => |a| {
            // If we have an array of complex underlying values, repair the underlying values.
            if (ComplexType(a.child)) {
                var index: usize = 0;
                while (index < a.len) : (index += 1) {
                    repair(@TypeOf(&value[index]), &value[index], a.child, allocator);
                }
            }
        },

        // nothing to do.
        else => {},
    }
}

pub fn dupe(comptime T: type, value: T, comptime Child: type, allocator: Allocator) !T {
    var duplicateSlice = try allocator.dupe(Child, @ptrCast([*]const Child, value)[0..1]);
    var duplicate = &duplicateSlice[0];

    repair(T, duplicate, Child, allocator);

    return duplicate;
}

test "compact simple pointer" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *u32 = try allocator.create(u32);
    ptr.* = 0x01234567;
    var dupePtr = try compact(*u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*, dupePtr.*);
}

test "compact simple array" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *[3]u32 = try allocator.create([3]u32);
    ptr.*[0] = 1;
    ptr.*[1] = 2;
    ptr.*[2] = 3;
    var dupePtr = try compact(*[3]u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*[0], dupePtr.*[0]);
    try std.testing.expectEqual(ptr.*[1], dupePtr.*[1]);
    try std.testing.expectEqual(ptr.*[2], dupePtr.*[2]);
}

test "compact simple struct" {
    const S = struct { a: u64, b: u32, c: u8 };
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *S = try allocator.create(S);
    ptr.a = 1;
    ptr.b = 2;
    ptr.c = 3;
    var dupePtr = try compact(*S, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.a, dupePtr.a);
    try std.testing.expectEqual(ptr.b, dupePtr.b);
    try std.testing.expectEqual(ptr.c, dupePtr.c);
}

test "compact simple union" {
    const U = union(enum) { a: u64, b: u32, c: u8 };
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *U = try allocator.create(U);
    ptr.* = U{ .a = 1 };
    var dupePtr = try compact(*U, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.a, dupePtr.a);
}

test "compact simple optional" {
    var heapAllocator = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = heapAllocator.allocator();
    var ptr: *?u32 = try allocator.create(?u32);
    ptr.* = 1;
    var dupePtr = try compact(*?u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
    try std.testing.expectEqual(ptr.*.?, dupePtr.*.?);

    ptr.* = null;
    var dupePtrNull = try compact(*?u32, ptr, allocator);
    try std.testing.expect(ptr != dupePtrNull);
    try std.testing.expectEqual(ptr.*, dupePtrNull.*);
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

    var ptr: *S2 = try allocator.create(S2);
    ptr.s1.* = try allocator.create(S1);
    ptr.s1.* = S1{ .a = 1, .b = 2, .c = 3 };
    ptr.s1_array = try allocator.create([3]S1);
    ptr.s1_array_ptrs = try allocator.create([3]*S1);
    var s1ptr = try allocator.create([3]S1);
    ptr.s1_slice = s1ptr[0..];

    var dupePtr = try compact(*S, ptr, allocator);
    try std.testing.expect(ptr != dupePtr);
}

// TODO implement 'seal' and 'unseal' functions:
// seal may take the start of an allocator's memory, and makes pointers
// relative to that location.
// Alternatively it could pass a root pointer downwards, making pointers relative
// to the initially provided pointer.
// Alternatively it could take a pointer initially, and then recurse using that base
// pointer as the relative offset. This seems like the best design.
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

