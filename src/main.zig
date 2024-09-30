const std = @import("std");

pub const compact = @import("compact.zig");
pub const seal = @import("seal.zig");

test "full test set" {
    _ = @import("compact.zig");
    _ = @import("seal.zig");
}
