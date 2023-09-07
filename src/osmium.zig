// Copyright (c) Adrian Alic <contact@alic.dev>
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

const std = @import("std");

/// A bounded stack-allocated vector that holds a max number of distinct
/// elements. Can be used during comptime.
pub fn StackVec(comptime T: type, comptime max: usize) type {
    return struct {
        const Self = @This();
        const Error = error{
            /// You tried pushing too much data to the bounded buffer.
            ExceededCapacity,
        };
        buffer: [max]T,
        len: usize,
        pub fn init() Self {
            return .{ .buffer = undefined, .len = 0 };
        }
        pub fn push(self: *Self, value: T) !void {
            if (self.len >= max) {
                return Error.ExceededCapacity;
            }
            self.buffer[self.len] = value;
            self.len += 1;
        }
        /// linear search, O(n)
        pub fn contains_slow(self: *Self, value: T) bool {
            for (self.items()) |elem| {
                if (elem == value) {
                    return true;
                }
            }
            return false;
        }
        pub fn items(self: *Self) []T {
            return self.buffer[0..self.len];
        }
    };
}

const ERR_01 = "Only enums with less than 256 variants are permitted";

/// A container that stores tagged unions. Does not support iteration. Only allows
/// appending elements, and retrieving/deleting elements via a tagged index.
pub fn DenseUnionArray(comptime inner: type) type {
    var svec = StackVec(usize, 256).init();
    const cfg = cfg: {
        switch (@typeInfo(inner)) {
            .Union => |u| {
                // every field maps to a corresponding array.

                var field_map = [_]u8{0} ** u.fields.len;
                const x = u.fields;
                for (x, 0..) |field, idx| {
                    field_map[idx] = svec.len;
                    const space = @max(field.alignment, @sizeOf(field.type));
                    if (!svec.contains_slow(space)) {
                        svec.push(space) catch @compileError(ERR_01);
                    }
                }
                break :cfg .{ .field_map = field_map, .sizes = svec };
            },
            else => @compileError("only unions allowed"),
        }
    };
    return struct {
        /// The union type stored in this collection
        const T = inner;
        const SelfTag = std.meta.Tag(T);
        const tag_values = std.enums.values(SelfTag);
        const tag_names = std.meta.fieldNames(SelfTag);
        const Self = @This();
        /// The Array-of-Variant-Arrays
        const AoVA = [cfg.sizes.len]std.ArrayList(u8);

        allocator: std.mem.Allocator,
        vecs: AoVA,

        pub fn init(a: std.mem.Allocator) Self {
            var v: AoVA = undefined;
            for (0..cfg.sizes.len) |i| {
                v[i] = std.ArrayList(u8).init(a);
            }
            return Self{ .allocator = a, .vecs = v };
        }
        /// Inserts the element into the container, and returns a tagged index.
        /// The index can be used to retrieve the element or delete it.
        /// Tagged indices are not contiguous and highly implementation-specific.
        pub fn append(self: *Self, item: T) std.mem.Allocator.Error!usize {
            var tag = std.meta.activeTag(item);
            // TODO: use comptime LUT instead of inline for
            inline for (tag_values, tag_names) |v, n| {
                if (tag == v) {
                    // cast the data typesafe to a byte array
                    const VariantType = std.meta.TagPayload(T, v);
                    const data: [@sizeOf(VariantType)]u8 = @bitCast(@field(item, n));
                    const tag_idx = @intFromEnum(v);
                    const aova_idx = comptime cfg.field_map[tag_idx];

                    // compute tagged index
                    var return_idx =
                        self.vecs[aova_idx].items.len / @sizeOf(VariantType);
                    // use low bits for tag
                    return_idx = return_idx << @bitSizeOf(SelfTag);
                    return_idx = return_idx | tag_idx;
                    // insert the data
                    try self.vecs[aova_idx].appendSlice(&data);
                    return return_idx; // make no-fall-through explicit
                }
            }
            return 0;
        }
    };
}
