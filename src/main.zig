// Copyright (c) Adrian Alic <contact@alic.dev>
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");
const osmium = @import("osmium.zig");

const Tag = enum { a, b, c, d, e, f, g };
const Enum = union(Tag) {
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u32,
    f: u32,
    g: u64,
};

pub fn main() !void {
    std.debug.print("\ninfo: Testing osmium\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = gpa.allocator();

    var abc = osmium.DenseUnionArray(Enum).init(alloc);
    const idx = try abc.append(Enum{ .a = 0xff });
    std.debug.print("idx: {}", .{idx});
}
