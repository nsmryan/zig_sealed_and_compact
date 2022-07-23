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
                    seal(@Type(child), value.*, offset, size);

                    const ptrLoc = @ptrToInt(value.*);
                    if (ptrLoc >= offset and (offset - ptrLoc) < size) {
                        value.* = @intToPtr(offset - ptrLoc);
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
                    // Seal each child structure. Consider avoiding this for
                    const sliceElementType = @TypeOf(value.*[0]);
                    if (compact.ComplexType(sliceElementType)) {
                        var index: usize = 0;
                        while (index < value.*.len) : (index += 1) {
                            try seal(@TypeOf(&value.*[index]), &value.*[index], allocator);
                        }
                    }

                    const ptrLoc = @ptrToInt(value.*.ptr);
                    if (ptrLoc >= offset and (offset - ptrLoc) < size) {
                        value.*.ptr = @intToPtr(offset - ptrLoc);
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
                var fieldPtr = &@field(value.*, field.name);
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
                    if (ComplexType(field.field_type)) {
                        // NOTE compile time error - we can't ensure correct duplication
                        // for untagged unions with pointers, as we don't know which field to copy.
                        unreachable;
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
                        try seal(@TypeOf(variantPtr), variantPtr, offset, size);
                    }
                }
            }
        },

        .Optional => {
            if (value.*) |inner| {
                try seal(@TypeOf(&inner), &inner, allocator);
                // TODO replace with sealed pointer
            }
        },

        // NOTE this doesn't necessarily handle terminated arrays correctly.
        .Array => |a| {
            // TODO implement
            // If we have an array of complex underlying values, repair the underlying values.
            if (ComplexType(a.child)) {
                var index: usize = 0;
                while (index < a.len) : (index += 1) {
                    try seal(@TypeOf(&value[index]), &value[index], offset, size);
                }
            }
        },

        // nothing to do.
        else => {},
    }
}

//pub fn seal_alloc(comptime T: type, ptr: T, allocator: Allocator) !void {
//    // TODO recurse on structure of
//}

//pub fn seal_into_buffer(comptime T: type, ptr: T, bytes: []u8) !void {
//}
