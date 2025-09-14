const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;
const assert = std.debug.assert;

/// Options for controlling serialization behavior.
pub const SerializerOptions = struct {
    /// The endianness to use when serializing data. For best performance,
    /// this should match the target architecture's endianness. Defaults to
    /// little-endian, since that's most common.
    ///
    /// Important: It's not safe to serialize data in one endianness and
    /// deserialize it in another, since some types (e.g. integers) will be
    /// misinterpreted.
    endianness: std.builtin.Endian = .little,
};

/// Serializer serializes values for zero-copy deserialization.
pub fn Serializer(comptime options: SerializerOptions) type {
    return struct {
        const Self = @This();

        // For now, we only support the native endianness of the target,
        // e.g. we don't do any byte-swapping. Non-trivial to do this well.
        comptime {
            const target_endianness = builtin.target.cpu.arch.endian();
            if (options.endianness != target_endianness) {
                @compileError("endianness must match target endianness");
            }
        }

        /// Helper type to keep track of the number of bytes written during serialization.
        const Written = struct {
            to_value: usize = 0,
            to_trailer: usize = 0,

            fn total(self: *const Written) usize {
                return self.to_value + self.to_trailer;
            }
        };

        alloc: std.mem.Allocator,

        /// The bytes that'll be re-interpreted as `SerializedRep(T)` upon deserialization.
        value: std.ArrayList(u8),

        /// The trailer bytes, e.g. extra bytes that can be referenced by relative pointers.
        trailer: std.ArrayList(u8),

        /// The list of relative pointers within either `value` or `trailer` that need to be adjusted
        /// before writing out the final serialized blob. Specifically, we don't know the final offsets
        /// until serialization is fully complete.
        ///
        /// Calling `fixRelPtrs` will peform the adjustment in-place, and clear this list. It must be
        /// called after all serialization is done, but before writing out the final blob.
        unfixed_relptrs: std.ArrayList(UnfixedRelPtr),

        /// Helper type to track an unfixed relative pointer that needs adjustment.
        const UnfixedRelPtr = struct {
            offset: u32,
            location: enum { value, trailer },
        };

        /// Initialize a new Serializer, which can be reused multiple times to serialize values.
        /// Maintains in-memory buffers to avoid repeated allocations.
        fn init(alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .value = .{},
                .trailer = .{},
                .unfixed_relptrs = .{},
            };
        }

        fn deinit(self: *Self) void {
            self.value.deinit(self.alloc);
            self.trailer.deinit(self.alloc);
            self.unfixed_relptrs.deinit(self.alloc);
            self.* = undefined;
        }

        /// Returns whether their is any in-memory state currently stored in this serializer.
        /// In general, this will be true if `serialize` has been called and `reset` has not been called since.
        fn empty(self: *const Self) bool {
            return self.value.items.len == 0 and
                self.trailer.items.len == 0 and
                self.unfixed_relptrs.items.len == 0;
        }

        /// Clears the in-memory state of this serializer, allowing it to be reused.
        /// Does not free any allocated memory, so reusing the serializer is efficient.
        /// To free all memory, call `deinit`.
        fn reset(self: *Self) void {
            self.value.clearRetainingCapacity();
            self.trailer.clearRetainingCapacity();
            self.unfixed_relptrs.clearRetainingCapacity();
            assert(self.empty());
        }

        /// Serializes a value into the in-memory state of this serializer.
        /// The value can later be written out with `writeTo`.
        fn serialize(self: *Self, value: anytype) !Written {
            const T = @TypeOf(value);
            return switch (@typeInfo(T)) {
                .void => .{},
                .int => blk: {
                    const aligned_type = std.math.ByteAlignedInt(T);
                    var buf: [@sizeOf(aligned_type)]u8 = undefined;
                    encodeFixed(options.endianness, &buf, @as(aligned_type, @intCast(value)));
                    try self.value.appendSlice(self.alloc, &buf);
                    break :blk .{ .to_value = buf.len, .to_trailer = 0 };
                },
                .float => |info| blk: {
                    switch (info.bits) {
                        16, 32, 64, 128 => {},
                        80 => @compileError("todo: support 80-bit floats"),
                        else => @compileError("unsupported float size: " ++ @tagName(info.bits)),
                    }
                    const unsigned_val: unsignedIntType(info.bits) = @bitCast(value);
                    break :blk self.serialize(unsigned_val);
                },
                .bool => blk: {
                    const byte: u8 = if (value) 1 else 0;
                    try self.value.append(self.alloc, byte);
                    break :blk .{ .to_value = 1, .to_trailer = 0 };
                },
                .@"enum" => |info| blk: {
                    const tag: info.tag_type = @intCast(@intFromEnum(value));
                    break :blk self.serialize(tag);
                },
                .@"struct" => |info| blk: {
                    var written: Written = .{};
                    inline for (info.fields) |field| {
                        const field_alignment = @alignOf(SerializedRep(field.type));
                        const padding_rem = written.to_value % field_alignment;
                        if (padding_rem > 0) {
                            const padding = field_alignment - padding_rem;
                            try self.value.appendNTimes(self.alloc, 0, padding);
                            written.to_value += padding;
                        }
                        const w = try self.serialize(@field(value, field.name));
                        written.to_value += w.to_value;
                        written.to_trailer += w.to_trailer;
                    }
                    const struct_alignment = @alignOf(SerializedRep(T));
                    const final_padding_rem = written.to_value % struct_alignment;
                    if (final_padding_rem > 0) {
                        const final_padding = struct_alignment - final_padding_rem;
                        try self.value.appendNTimes(self.alloc, 0, final_padding);
                        written.to_value += final_padding;
                    }
                    break :blk written;
                },
                .pointer => |info| switch (info.size) {
                    .one => blk: {
                        // Pointers are tricky - they emit a `u32` offset into the value section,
                        // and the actual data is appended to the trailer section.

                        // Serialize the inner value recursively. Notably, this will write the value
                        // data to the wrong section, we'll fix that below. We do it this way to properly
                        // handle nested pointers.
                        const original_unfixed_relptr_len = self.unfixed_relptrs.items.len;
                        var written = try self.serialize(value.*);

                        // Fix the alignment, e.g. make sure the trailer is padded appropriately
                        // s.t. that the inner value is properly aligned.
                        const inner_alignment = @alignOf(SerializedRep(info.child));
                        const aligned_trailer_len = std.mem.alignForward(usize, self.trailer.items.len, inner_alignment);
                        const trailer_padding = aligned_trailer_len - self.trailer.items.len;
                        if (trailer_padding > 0) {
                            try self.trailer.appendNTimes(self.alloc, 0, trailer_padding);
                            written.to_trailer += trailer_padding;
                        }

                        // Move the inner value bytes from the value section to the trailer section.
                        const original_value_length = self.value.items.len - written.to_value;
                        const inner_written_bytes = self.value.items[original_value_length..];
                        const trailer_offset = @as(u32, @intCast(self.trailer.items.len));
                        try self.trailer.appendSlice(self.alloc, inner_written_bytes);
                        self.value.resize(self.alloc, original_value_length) catch unreachable; // Truncation
                        written.to_trailer += written.to_value;

                        // For any relative pointers in the inner value, we need to adjust their location
                        // to be in the trailer section now.
                        const new_unfixed_relptr_len = self.unfixed_relptrs.items.len;
                        for (original_unfixed_relptr_len..new_unfixed_relptr_len) |i| {
                            self.unfixed_relptrs.items[i].offset -= @as(u32, @intCast(original_value_length));
                            self.unfixed_relptrs.items[i].offset += trailer_offset;
                            self.unfixed_relptrs.items[i].location = .trailer;
                        }

                        // Write the offset to the inner value in the trailer.
                        const rel_ptr_offset = @as(u32, @intCast(self.value.items.len));
                        const rel_ptr_w = try self.serialize(trailer_offset);
                        written.to_value = rel_ptr_w.to_value;
                        assert(rel_ptr_w.to_trailer == 0);

                        // The relative pointer needs to be adjusted when writing out the final blob.
                        try self.unfixed_relptrs.append(self.alloc, .{
                            .offset = rel_ptr_offset,
                            .location = .value,
                        });

                        break :blk written;
                    },
                    else => @compileError("unsupported pointer size: " ++ @tagName(info.size)),
                },
                else => unsupportedType(T),
            };
        }

        /// If there are any relative pointers that need adjustment, perform the adjustment in-place.
        /// Must be called after all serialization is done, but before writing out.
        fn fixRelPtrs(self: *Self) void {
            const value_len = @as(u32, @intCast(self.value.items.len));
            for (self.unfixed_relptrs.items) |unfixed_rp| {
                const ptr_bytes = switch (unfixed_rp.location) {
                    .value => self.value.items[unfixed_rp.offset .. unfixed_rp.offset + 4],
                    .trailer => self.trailer.items[unfixed_rp.offset .. unfixed_rp.offset + 4],
                };
                const trailer_offset = decodeFixed(u32, options.endianness, ptr_bytes);
                const adjusted = value_len + trailer_offset;
                encodeFixed(options.endianness, ptr_bytes, adjusted);
            }
            self.unfixed_relptrs.clearRetainingCapacity();
        }

        /// Writes the in-memory state of this serializer to a writer.
        /// Doesn't clear or modify anything, can be called multiple times.
        fn writeTo(self: *Self, writer: *std.Io.Writer) !void {
            self.fixRelPtrs();
            assert(self.unfixed_relptrs.items.len == 0); // All adjustments should be done.
            try writer.writeAll(self.value.items);
            try writer.writeAll(self.trailer.items);
        }

        /// Helper function to serialize a value, and immediately write it to a writer.
        /// Asserts that the serializer is empty before, and will reset it after, e.g. can
        /// be called multiple times in a row.
        fn serializeTo(self: *Self, writer: *std.Io.Writer, value: anytype) !Written {
            assert(self.empty());
            defer self.reset(); // We can reuse the serializer after this.

            // Serialize the bytes into our in-memory buffer.
            const written = try self.serialize(value);
            assert(written.to_value == self.value.items.len);

            // Dump the bytes to the writer.
            try self.writeTo(writer);

            return written;
        }
    };
}

/// Returns a unsigned integer type that can hold the given number of bits.
fn unsignedIntType(comptime bits: u16) type {
    return @Type(.{
        .int = .{ .bits = bits, .signedness = .unsigned },
    });
}

/// A relative pointer, e.g. pointing to an offset within the same byte buffer. The pointer
/// can be resolved to a value by following the offset from a base pointer (e.g. the start of the buffer).
pub fn SerializedPtr(comptime T: type) type {
    return extern struct {
        const Self = @This();

        offset: u32,

        pub fn resolve(self: *const Self, base_ptr: [*]const u8) *const SerializedRep(T) {
            const target_ptr = base_ptr + self.offset;

            return @ptrCast(@alignCast(target_ptr));
        }
    };
}

/// SerializedRep is a view of a serialized type T, e.g. returned from deserialization.
/// Specifically, for some types, we can't rely on Zig to give us a consistent byte layout
/// across compiler versions or platforms, so this type implements a consistent layout.
pub fn SerializedRep(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .void, .bool => T, // Trivially represented types; consistent layout.
        .int => std.math.ByteAlignedInt(T),
        .float => |info| blk: {
            switch (info.bits) {
                16, 32, 64, 128 => {},
                80 => @compileError("todo: support 80-bit floats"),
                else => @compileError("unsupported float size: " ++ @tagName(info.bits)),
            }
            break :blk T;
        },
        .@"enum" => |info| SerializedRep(info.tag_type),
        .@"struct" => |info| blk: {
            // The serialized view of a struct is simply a struct, where all the fields have
            // been transformed into their Serialized view.
            comptime var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            inline for (info.fields, 0..) |f, i| {
                fields[i] = .{
                    .name = f.name,
                    .type = SerializedRep(f.type),
                    .alignment = @alignOf(SerializedRep(f.type)),
                    .default_value_ptr = null,
                    .is_comptime = false,
                };
            }
            break :blk @Type(.{
                .@"struct" = .{
                    .layout = .@"extern", // Force a consistent layout.
                    .fields = &fields,
                    .decls = &[_]std.builtin.Type.Declaration{},
                    .is_tuple = false,
                },
            });
        },
        .pointer => |info| switch (info.size) {
            .one => SerializedPtr(info.child),
            else => @compileError("unsupported pointer size: " ++ @tagName(info.size)),
        },
        else => unsupportedType(T),
    };
}

/// Returns whether a value is logically equivalent to a serialized view of itself.
/// The types themselves may differ, e.g. `SerializedRep(T)` may be a different type than `T`,
/// but checks whether logically they represent the same data.
///
/// Mostly used for testing at the moment.
fn logicallyEqualToSerialized(value: anytype, deserialized: View(@TypeOf(value))) bool {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .bool => value == deserialized.view().*,
        .float => blk: {
            if (std.math.isNan(value)) {
                break :blk std.math.isNan(deserialized.view().*);
            }
            break :blk std.math.approxEqRel(
                T,
                value,
                deserialized.view().*,
                std.math.floatEps(T),
            );
        },
        .@"enum" => |info| blk: {
            const aligned_type = std.math.ByteAlignedInt(info.tag_type);
            const as_byte_aligned: aligned_type = @intCast(@intFromEnum(value));
            break :blk as_byte_aligned == deserialized.view().*;
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                const v_field = @field(value, field.name);
                const s_field = deserialized.field(field.name);
                if (!logicallyEqualToSerialized(v_field, s_field)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .pointer => |info| switch (info.size) {
            .one => logicallyEqualToSerialized(value.*, deserialized.deref()),
            else => @compileError("unsupported pointer size: " ++ @tagName(info.size)),
        },
        else => unsupportedType(T),
    };
}

/// Returns the type associated with a struct field, by name.
fn structFieldType(comptime S: type, comptime field_name: []const u8) type {
    return switch (@typeInfo(S)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    break :blk field.type;
                }
            }
            @compileError("no such field: " ++ field_name);
        },
        else => @compileError("not a struct"),
    };
}

/// View is an accessor type for a serialized value of type T.
/// Depending on the type T, the view may provide different methods to access the data,
/// e.g. pointers will be resolved with `deref()`, structs will have `field()` accessors, etc.
///
/// This is one shortcoming of Zig's lack of trait-based accessors, e.g. we can't implement
/// Deref or Index traits like in Rust, so we have to rely on methods on compile-time generated types.
/// TODO maybe some way to clean this up and make it more ergonomic?
fn View(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .one => struct {
                value: *const SerializedPtr(info.child),
                base_ptr: [*]const u8,

                fn deref(self: @This()) View(info.child) {
                    return .{
                        .value = self.value.resolve(self.base_ptr),
                        .base_ptr = self.base_ptr,
                    };
                }
            },
            else => @compileError("unsupported pointer size: " ++ @tagName(info.size)),
        },
        .@"struct" => struct {
            value: *const SerializedRep(T),
            base_ptr: [*]const u8,

            fn field(self: @This(), comptime name: []const u8) View(structFieldType(T, name)) {
                return .{
                    .value = &@field(self.value, name),
                    .base_ptr = self.base_ptr,
                };
            }
        },
        else => struct {
            value: *const SerializedRep(T),
            base_ptr: [*]const u8,

            fn view(self: @This()) *const SerializedRep(T) {
                return self.value;
            }
        },
    };
}

/// Deserializes a value of type T from a byte buffer. Specifically, returns a pointer to a `SerializedRep(T)`,
/// aka a logically equivalent view of T. The lifetime of the returned pointer is tied to the lifetime of the
/// provided buffer, e.g. the buffer must outlive the returned pointer.
pub fn deserialize(comptime T: type, serialized: []const u8) View(T) {
    return .{
        .value = @ptrCast(@alignCast(serialized.ptr)),
        .base_ptr = serialized.ptr,
    };
}

/// Encodes a fixed-width integer type into a byte buffer, in the specified endianness.
/// The buffer must be at least the size of the type.
pub fn encodeFixed(comptime order: std.builtin.Endian, buf: []u8, val: anytype) void {
    const T = @TypeOf(val);
    const size = @sizeOf(T);
    const signed = @typeInfo(T).int.signedness == .signed;
    assert(buf.len >= size);
    if (comptime order == .little) {
        inline for (0..size) |i| {
            buf[i] = if (comptime signed) blk: {
                const truncated: i8 = @truncate(val >> (comptime i * 8));
                break :blk @as(u8, @bitCast(truncated));
            } else @as(u8, @truncate(val >> (comptime i * 8)));
        }
    } else {
        inline for (0..size) |i| {
            buf[comptime size - 1 - i] = if (comptime signed) blk: {
                const truncated: i8 = @truncate(val >> (comptime i * 8));
                break :blk @as(u8, @bitCast(truncated));
            } else @as(u8, @truncate(val >> (comptime (i * 8))));
        }
    }
}

/// Helper function to mark a type as unable to be serialized/deserialized.
fn unsupportedType(comptime T: type) noreturn {
    @compileError("type " ++ @typeName(T) ++ " is not supported for serialization/deserialization with cryoz");
}

/// Decodes a fixed-width integer type from a byte buffer, in the specified endianness.
/// The buffer must be at least the size of the type.
pub fn decodeFixed(comptime T: type, comptime order: std.builtin.Endian, encoded: []const u8) T {
    const size = @sizeOf(T);
    assert(encoded.len >= size);
    var res: T = 0;
    if (comptime order == .little) {
        inline for (0..size) |i| {
            res |= @as(T, @intCast(encoded[i])) << (comptime i * 8);
        }
    } else {
        inline for (0..size) |i| {
            res |= @as(T, @intCast(encoded[comptime size - 1 - i])) << (comptime i * 8);
        }
    }
    return res;
}

test "comptime type fixed encoding/decoding" {
    const types = [_]type{ u8, i8, u16, i16, u32, i32, u64, i64, u128, i128 };
    inline for (types) |typ| {
        var buf: [@sizeOf(typ)]u8 = undefined;
        const value: typ = 127;
        inline for (&[_]std.builtin.Endian{ .little, .big }) |ord| {
            encodeFixed(ord, &buf, value);
            const decoded = decodeFixed(typ, ord, &buf);
            try testing.expectEqual(value, decoded);
        }
    }
}

// Void is the most basic type, it's a no-op.
test "void" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const written = try serializer.serializeTo(&alloc_writer.writer, @as(void, {}));
    try testing.expectEqual(0, written.to_value);

    const deserialized = deserialize(void, alloc_writer.written());
    try testing.expectEqual(@as(void, {}), deserialized.view().*);
}

// Integers are pretty trivial; just read/write them in the compile-time defined endianness.
// Zig will natively represent them in the target's endianness.
test "integers" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const types = [_]type{ u8, u16, u32, u64, i8, i16, i32, i64 };
    inline for (types) |T| {
        const experiments = [_]T{
            std.math.minInt(T),
            std.math.minInt(T) / 2,
            std.math.maxInt(T),
            std.math.maxInt(T) / 2,
            0,
        };
        for (experiments) |value| {
            defer alloc_writer.clearRetainingCapacity();
            const written = try serializer.serializeTo(&alloc_writer.writer, value);
            try testing.expectEqual(@sizeOf(T), written.to_value);

            const deserialized = deserialize(T, alloc_writer.written());
            try testing.expect(logicallyEqualToSerialized(value, deserialized));
        }
    }
}

// Non-byte aligned integers are represented as the next largest byte-aligned integer.
test "non-byte aligned integers" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const value = @as(u3, 5);
    const written = try serializer.serializeTo(&alloc_writer.writer, value);
    try testing.expectEqual(1, written.total());

    const deserialized = deserialize(u3, alloc_writer.written());
    try testing.expect(logicallyEqualToSerialized(value, deserialized));
}

// Floating points are supported, since Zig guarantees their layout is consistent across platforms.
test "floats" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const types = [_]type{ f16, f32, f64, f128 };
    inline for (types) |T| {
        const experiments = [_]T{
            -1.0,
            0.0,
            1.0,
            3.14159,
            -3.14159,
            std.math.floatMax(T),
            std.math.floatMin(T),
            std.math.floatEps(T),
            std.math.nan(T),
        };
        for (experiments) |value| {
            defer alloc_writer.clearRetainingCapacity();
            const written = try serializer.serializeTo(&alloc_writer.writer, value);
            try testing.expectEqual(@sizeOf(T), written.to_value);

            const deserialized = deserialize(T, alloc_writer.written());
            try testing.expect(logicallyEqualToSerialized(value, deserialized));
        }
    }
}

// Booleans are just a single byte, 0 or 1.
test "booleans" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const experiments = [_]bool{ false, true };
    for (experiments) |value| {
        defer alloc_writer.clearRetainingCapacity();
        const written = try serializer.serializeTo(&alloc_writer.writer, value);
        try testing.expectEqual(1, written.to_value);

        const deserialized = deserialize(bool, alloc_writer.written());
        try testing.expect(logicallyEqualToSerialized(value, deserialized));
    }
}

// Enums are simple wrappers around integers. For enums that aren't byte aligned (e.g. u3), we'll
// store them as the next largest byte-aligned integer (e.g. u8).
test "enums" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const untagged_type = enum { a, b, c };
    const tagged_type = enum(u8) { a = 0, b = 1, c = 2 };

    const experiments = &.{
        untagged_type.a,
        untagged_type.b,
        untagged_type.c,
        tagged_type.a,
        tagged_type.b,
        tagged_type.c,
    };
    inline for (experiments) |value| {
        defer alloc_writer.clearRetainingCapacity();
        const written = try serializer.serializeTo(&alloc_writer.writer, value);
        try testing.expectEqual(@sizeOf(@TypeOf(value)), written.to_value);

        const deserialized = deserialize(@TypeOf(value), alloc_writer.written());
        try testing.expect(logicallyEqualToSerialized(value, deserialized));
    }
}

// Structs are a bit more interesting, since they're composed of multiple fields, and we need to
// ensure proper alignment / padding between fields.
test "structs" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const experiments = &.{
        .{ struct { a: u8 }{ .a = 123 }, 1 },
        .{ struct { a: bool, b: bool }{ .a = true, .b = false }, 2 },
        .{ struct { a: bool, b: u16 }{ .a = true, .b = 12345 }, 4 },
        .{ struct { a: u8, b: u16, c: u32, d: u64 }{ .a = 1, .b = 2, .c = 3, .d = 4 }, 16 },
        .{ struct { a: u64, b: u32, c: u16, d: u8 }{ .a = 1, .b = 2, .c = 3, .d = 4 }, 16 },
        .{ struct { a: u8, b: struct { x: u32, y: u16 } }{ .a = 1, .b = .{ .x = 2, .y = 3 } }, 12 },
    };
    inline for (experiments) |exp| {
        defer alloc_writer.clearRetainingCapacity();

        const val = exp.@"0";
        const expected_size = exp.@"1";

        const written = try serializer.serializeTo(&alloc_writer.writer, val);
        try testing.expectEqual(expected_size, written.to_value);

        const deserialized = deserialize(@TypeOf(val), alloc_writer.written());
        try testing.expect(logicallyEqualToSerialized(val, deserialized));
    }
}

// Pointers are decently complex, since they rely on writing to the trailer section and storing a
// relative pointer in the value section. Specifically, the actual encoded value is just a u32-offset
// into the trailing bytes of the slice, where the actual data is stored.
test "pointers" {
    const allocator = testing.allocator;

    var serializer = Serializer(.{}).init(allocator);
    defer serializer.deinit();

    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();

    const experiments = &.{
        .{ &@as(u8, 123), &[_]u8{ 4, 0, 0, 0, 0x7b } },
        .{ &struct { a: u8 }{ .a = 45 }, &[_]u8{ 4, 0, 0, 0, 45 } },
        .{
            struct {
                a: *const u8,
                b: *const u8,
            }{
                .a = &1,
                .b = &2,
            },
            &[_]u8{
                0x08, 0x00, 0x00, 0x00, // offset to a
                0x09, 0x00, 0x00, 0x00, // offset to b
                0x01, // a value (e.g. within trailer)
                0x02, // b value (e.g. within trailer)
            },
        },
        .{
            &struct {
                a: *const u8,
                b: *const u8,
            }{
                .a = &0x69,
                .b = &0x42,
            },
            &[_]u8{
                0x08, 0x00, 0x00, 0x00, // rel ptr (outer struct)
                // trailer start
                0x69, // value of a
                0x42, // value of b
                0x00, 0x00, // padding for alignment (e.g. outer struct 4-byte aligned)
                0x04, 0x00, 0x00, 0x00, // rel ptr (a)
                0x05, 0x00, 0x00, 0x00, // rel ptr (b)
            },
        },
    };
    inline for (experiments) |exp| {
        defer alloc_writer.clearRetainingCapacity();

        const val = exp.@"0";
        const expected_bytes = exp.@"1";

        const written = try serializer.serializeTo(&alloc_writer.writer, val);
        try testing.expectEqualSlices(u8, expected_bytes, alloc_writer.written());
        try testing.expectEqual(expected_bytes.len, written.total());

        const deserialized = deserialize(@TypeOf(val), alloc_writer.written());
        try testing.expect(logicallyEqualToSerialized(val, deserialized));
    }
}
