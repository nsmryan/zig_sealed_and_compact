const std = @import("std");
const testing = std.testing;

const compact = @import("compact.zig");
const seal = @import("seal.zig");

test "full test set" {
    _ = @import("compact.zig");
    _ = @import("seal.zig");
}
