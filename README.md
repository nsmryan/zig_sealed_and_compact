![](https://github.com/DomKalinowski/zig_sealed_and_compact/actions/workflows/validate-and-test.yml/badge.svg)

# Zig Seal/Unseal and Compact

This repository contains an implementation of two concepts in Zig:

  * A generic deep copy into memory provided by a given allocator. 
    This is called 'compact' because I intend to use it with a FixedBufferAllocator to compact sprawling memory layouts into a single buffer.
  * A way to 'seal' and 'unseal' an object in memory, meaning that all of its pointers are relative to a given location. This makes the structure relocatable.


For some context- say you have some large structure, perhaps the state of a game, and you want to occasionally save or restore this structure.


One way to do this is to simply traverse the structure, pushing it into a bump allocator (FixedBufferAllocator in the Zig standard library),
such that you end up with a copy of the structure in a known memory area rather then through allocations from the system or other allocator.


Even with this copy, it could not be saved or restored from disk because any pointers within it are to absolute (virtual) memory addresses.
That is where 'seal' comes in- it generically traverses a structure looking for pointers (and slices) and will make them relative to a give location.
This location would, for example, be the start of the memory buffer that the FixedBufferAllocator uses.


With this 'sealed' version of the structure, you could move it in memory, store it to disk, etc. When you are ready to 'unseal' it, making it usable
again, you would call 'unseal' with the offset of the start of the FixedBufferAllocator, and the structure would be usable again.


In a way this is like a serialization scheme that does not need to encode or decode your data- it just does a little arithmatic for each pointer.
It should be fairly fast for this reason- it is all comptime generated code specific to the structure, and will only modify fields that are required.

## Functions

```zig
/// Deep copy a structure into memory provided by a given allocator.
pub fn compact(comptime T: type, value: T, allocator: Allocator) AllocatorError!T;

/// Seal a structure so it is relocatable. The structure will be unusable after this call
/// until it is passed to unseal.
pub fn seal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void;

/// Undoes the action of 'seal', making the structure usable again.
pub fn unseal(comptime T: type, ptr: T, offset: usize, size: usize) SealError!void;

/// Copy a structure into the given byte buffer and seal it. The result is a buffer that can be copied,
/// stored, etc, and unsealed manually or passed to unseal_from_buffer.
// This function returns how much memory was used from the 'bytes' buffer.
pub fn seal_into_buffer(comptime T: type, ptr: T, bytes: []u8) !usize;

/// Reallocate a structure from the sealed version in a buffer into memory supplied by the given allocator.
pub fn unseal_from_buffer(comptime T: type, bytes: []u8, allocator: Allocator) !T;
```

## C/Rust

I have considered doing something like this in C or Rust. In C I would just implement each concept (copying or seal/unseal) for each data structure
I wanted, effectively manually performing the comptime work that Zig does for me. Perhaps this could be done automatically in C++ with some template
magic (I really have no idea), but it seems pretty much impossible to implement in C directly. Indirectly perhaps inspection of DWARF debug info or
something could be used to generate code for this kind of thing, but that is getting to be a much bigger problem to solve.


In Rust, I don't know how to do any better then manually written functions. Perhaps there is some macro magic that would make this work similar to
how serde operates. I suspect it would require, at least, a custom derive to be added to all structures you want to use this with. Rust's type
system is considerably more complex then Zig's so I expect the list of limitations would be longer to include such things as lifetime variables
in types which make no sense when serialized.


This version in Zig is 'open' in the sense that it can handle structures that it has never seen, and there is no orphan rule limitation that might
make a user defined trait for these things limited in interoperation between libraries. However, Zig's genericness also means that you have no
option to fill in a user provided implementation (such as a Rust trait that is written manually for a specific type). Perhaps some of the limitations
below would be addressable in a system that allows user provided implementations for some types. 

In Zig this might be doable in some comptime
inspection of a type's declarations (looking for a 'compact' field or something), but I'm not planning on exploring that design space.
Another idea would be a global registry of functions, one per type, which would be dispatched to when available while traversing a type. I'm also
not planning on exploring that space at the moment.


## Limitations

There are a few limitations I came across while implementing this concept.

    * C pointers cannot be relocated or sealed- there is no way to be sure that this is reasonable. One could assume that they are allocated
      by a Zig allocator, and therefore could be at least sealed, but this seems dangerous. They cannot be relocated because we can't tell how
      much data to copy.
    * Multi valued pointers in Zig cannot be deep copied because we don't know how many items they point to. They can be sealed and unsealed only
      if they point to simple types that don't themselves need sealing and unsealing. If they point to complex types we don't know how many elements
      of those types to operate on, and we are in the same situation as with a deep copy.
    * Sentinal terminated arrays don't work when deep copying- even if we looked for the sentinal, I don't know that this is the right thing to do.
    * Opaque types obviously do not work- we don't know how to traverse them.
    * Frames and functions may work within a run of a program, but I doubt then restoring them from disk will do any good. I did not attempt to handle
      them specially. If this were production code, I may explicitly forbid them to avoid a function pointer getting loaded from disk and jumped to.

One other note - I did not test this with 0 sized types. It may work, it may not.

## Notes

The 'seal'/'unseal' concept is based on some work in Haskell for packaging data into a single memory area that could be loaded to disk and back to memory.
I seem to recall that the idea was that you did not have to modify the memory once it was loaded, although I'm not sure how that was done.

I think the library I was thinking of was this: https://hackage.haskell.org/package/compact, although rereading it they were actually working on something
a bit different.

## Workflow

When working on the library consider using `watchexec` to automaticaly re-run tests on save:
```
watchexec -c -e zig zig build test --verbose
```
