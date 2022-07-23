const std = @import("std");
const trait = std.meta.trait;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const AllocatorError = std.mem.Allocator.Error;

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

