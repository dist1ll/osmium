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

/// Aova = Array of Variant Arrays
///
/// A maximally dense Aova, clustered by type size (or alignment, if larger).
/// - Single-insertion. Returns tagged index w/ union tag
/// - No type-safe iteration (use AovaIterable instead)
/// - Allows swapRemove
pub fn AovaDense(comptime inner: type) type {
    var svec = StackVec(usize, 256).init();
    const cfg = cfg: {
        switch (@typeInfo(inner)) {
            .Union => |u| {
                // every field maps to a corresponding array.
                var field_map = [_]u8{0} ** u.fields.len;
                for (u.fields, 0..) |field, idx| {
                    const space = @max(field.alignment, @sizeOf(field.type));
                    if (!svec.contains_slow(space)) {
                        svec.push(space) catch @compileError(ERR_01);
                    }
                    field_map[idx] = svec.len - 1;
                }
                break :cfg .{ .field_map = field_map, .sizes = svec };
            },
            else => @compileError("only unions allowed"),
        }
    };
    return struct {
        const Self = @This();
        const Error = error{
            IndexOutOfBounds,
            /// Too many elements to index, leaving no room for tag bits.
            /// Example: You have a tagged union with 30 variants. The
            /// enum tag occupies at least 5 bits, leaving 64-5 = 61 bits
            /// for the index. Thus, if you attempt to append the 2^61-th item,
            /// this error will be returned.
            ExhaustedIndexSpace,
        };
        /// The union type stored in this collection
        const T = inner;
        const SelfTag = std.meta.Tag(T);
        const tag_values = std.enums.values(SelfTag);
        const tag_names = std.meta.fieldNames(SelfTag);
        const tag_mask = ((1 << @bitSizeOf(SelfTag)) - 1);
        /// The Array-of-Variant-Arrays
        const AoVA = [cfg.sizes.len]std.ArrayList(u8);
        const TaggedIndex = struct { inner: usize };

        allocator: std.mem.Allocator,
        vecs: AoVA,

        /// Deinitialize with `deinit`.
        pub fn init(a: std.mem.Allocator) Self {
            var v: AoVA = undefined;
            for (0..cfg.sizes.len) |i| {
                v[i] = std.ArrayList(u8).init(a);
            }
            return Self{ .allocator = a, .vecs = v };
        }
        /// Release all allocated memory.
        pub fn deinit(self: Self) void {
            for (self.vecs) |arr| {
                arr.deinit();
            }
        }
        pub fn get(self: *Self, tidx: TaggedIndex) T {
            const tag: SelfTag = @enumFromInt(tidx.inner & tag_mask);
            // TODO: replace with LUT
            inline for (tag_values, tag_names) |v, n| {
                if (tag == v) {
                    // calculate size of tag class
                    // TODO: Remove this boilerplate
                    const tag_idx = @intFromEnum(v);
                    const aova_idx = comptime cfg.field_map[tag_idx];
                    const data_len = comptime cfg.sizes.buffer[aova_idx];

                    const idx = (tidx.inner >> @bitSizeOf(SelfTag)) * data_len;

                    // memcpy into byte array, typecast, and construct union
                    const src = self
                        .vecs[aova_idx]
                        .items[idx..(idx + data_len)];
                    var dst: [data_len]u8 = [_]u8{0} ** data_len;
                    _ = @memcpy(&dst, src);

                    const cast: std.meta.TagPayload(T, v) = @bitCast(dst);
                    return @unionInit(T, n, cast);
                }
            }
            unreachable;
        }
        /// Inserts the element into the container, and returns a tagged index.
        /// The index can be used to retrieve the element or delete it.
        /// Tagged indices are not contiguous and highly implementation-specific.
        pub fn append(self: *Self, item: T) !TaggedIndex {
            var tag = std.meta.activeTag(item);
            // TODO: use comptime LUT instead of inline for
            inline for (tag_values, tag_names) |v, n| {
                if (tag == v) {
                    // calculate size of this tag class
                    const tag_idx = @intFromEnum(v);
                    const aova_idx = comptime cfg.field_map[tag_idx];
                    const data_len = comptime cfg.sizes.buffer[aova_idx];

                    // cast the data typesafe to a byte array
                    const data: [data_len]u8 = @bitCast(@field(item, n));

                    // compute tagged index
                    var return_idx = self.vecs[aova_idx].items.len / data_len;

                    // SAFETY: index needs to leave enough room for tag bits
                    if (return_idx >=
                        (1 << (@bitSizeOf(usize) - @bitSizeOf(SelfTag))))
                    {
                        return Error.ExhaustedIndexSpace;
                    }

                    // Insert tag into low bits
                    return_idx = return_idx << @bitSizeOf(SelfTag);
                    return_idx = return_idx | tag_idx;

                    // insert the data
                    try self.vecs[aova_idx].appendSlice(&data);
                    return .{ .inner = return_idx }; // make no-fall-through explicit
                }
            }
            unreachable;
        }
        /// Removes the element given by the tagged index, by swapping in the
        /// last element.
        pub fn swapRemove(self: *Self, tagged_idx: TaggedIndex) !void {
            const tag = tagged_idx.inner & tag_mask;
            const idx = tagged_idx.inner >> @bitSizeOf(SelfTag);
            const aova_idx = cfg.field_map[tag];
            const data_len = cfg.sizes.buffer[aova_idx];
            const byte_idx = idx * data_len;
            const last_byte_idx = self.vecs[aova_idx].items.len - data_len;

            // if target isn't last element, swap with last element
            if (byte_idx < last_byte_idx) {
                const dst =
                    self.vecs[aova_idx].items[byte_idx..(byte_idx + data_len)];
                const src = self.vecs[aova_idx]
                    .items[last_byte_idx..(last_byte_idx + data_len)];
                @memcpy(dst, src);
            } else if (byte_idx > last_byte_idx) {
                return Error.IndexOutOfBounds;
            }

            // truncate vec
            try self.vecs[aova_idx].resize(last_byte_idx);
        }
    };
}
