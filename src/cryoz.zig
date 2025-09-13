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
            to_value: usize,
        };

        alloc: std.mem.Allocator,

        /// The bytes that'll be re-interpreted as `Serialized(T)` upon deserialization.
        value: std.ArrayList(u8),

        /// Initialize a new Serializer, which can be reused multiple times to serialize values.
        /// Maintains in-memory buffers to avoid repeated allocations.
        fn init(alloc: std.mem.Allocator) Self {
            return .{
                .alloc = alloc,
                .value = .{},
            };
        }

        fn deinit(self: *Self) void {
            self.value.deinit(self.alloc);
            self.* = undefined;
        }

        /// Returns whether their is any in-memory state currently stored in this serializer.
        /// In general, this will be true if `serialize` has been called and `reset` has not been called since.
        fn empty(self: *const Self) bool {
            return self.value.items.len == 0;
        }

        /// Clears the in-memory state of this serializer, allowing it to be reused.
        /// Does not free any allocated memory, so reusing the serializer is efficient.
        /// To free all memory, call `deinit`.
        fn reset(self: *Self) void {
            self.value.clearRetainingCapacity();
            assert(self.empty());
        }

        /// Serializes a value into the in-memory state of this serializer.
        /// The value can later be written out with `writeTo`.
        fn serialize(self: *Self, value: anytype) !Written {
            const T = @TypeOf(value);
            return switch (@typeInfo(T)) {
                .int => blk: {
                    var buf: [@sizeOf(T)]u8 = undefined;
                    encodeFixed(options.endianness, &buf, value);
                    try self.value.appendSlice(self.alloc, &buf);
                    break :blk .{ .to_value = buf.len };
                },
                .bool => blk: {
                    const byte: u8 = if (value) 1 else 0;
                    try self.value.append(self.alloc, byte);
                    break :blk .{ .to_value = 1 };
                },
                .@"enum" => |info| blk: {
                    const aligned_type = std.math.ByteAlignedInt(info.tag_type);
                    const tag: aligned_type = @intCast(@intFromEnum(value));
                    break :blk self.serialize(tag);
                },
                .@"struct" => |info| blk: {
                    var written: Written = .{ .to_value = 0 };
                    inline for (info.fields) |field| {
                        const field_alignment = @alignOf(Serialized(field.type));
                        const padding_rem = written.to_value % field_alignment;
                        if (padding_rem > 0) {
                            const padding = field_alignment - padding_rem;
                            try self.value.appendNTimes(self.alloc, 0, padding);
                            written.to_value += padding;
                        }
                        const w = try self.serialize(@field(value, field.name));
                        written.to_value += w.to_value;
                    }
                    const struct_alignment = @alignOf(Serialized(T));
                    const final_padding_rem = written.to_value % struct_alignment;
                    if (final_padding_rem > 0) {
                        const final_padding = struct_alignment - final_padding_rem;
                        try self.value.appendNTimes(self.alloc, 0, final_padding);
                        written.to_value += final_padding;
                    }
                    break :blk written;
                },
                else => unsupportedType(T),
            };
        }

        /// Writes the in-memory state of this serializer to a writer.
        /// Doesn't clear or modify anything, can be called multiple times.
        fn writeTo(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.value.items);
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

/// Serialized is a view of a serialized type T, e.g. returned from deserialization.
/// Specifically, for some types, we can't rely on Zig to give us a consistent byte layout
/// across compiler versions or platforms, so this type implements a consistent layout.
pub fn Serialized(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int, .bool => T, // Trivially represented types; consistent layout.
        .@"enum" => |info| std.math.ByteAlignedInt(info.tag_type),
        .@"struct" => |info| blk: {
            // The serialized view of a struct is simply a struct, where all the fields have
            // been transformed into their Serialized view.
            comptime var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            inline for (info.fields, 0..) |f, i| {
                fields[i] = .{
                    .name = f.name,
                    .type = Serialized(f.type),
                    .alignment = @alignOf(Serialized(f.type)),
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
        else => unsupportedType(T),
    };
}

/// Returns whether a value is logically equivalent to a serialized view of itself.
/// The types themselves may differ, e.g. `Serialized(T)` may be a different type than `T`,
/// but checks whether logically they represent the same data.
///
/// Mostly used for testing at the moment.
fn logicallyEqualToSerialized(value: anytype, serialized: *const Serialized(@TypeOf(value))) bool {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .bool => return value == serialized.*,
        .@"enum" => |info| {
            const aligned_type = std.math.ByteAlignedInt(info.tag_type);
            const as_byte_aligned: aligned_type = @intCast(@intFromEnum(value));
            return as_byte_aligned == serialized.*;
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const v_field = @field(value, field.name);
                const s_field = @field(serialized.*, field.name);
                if (!logicallyEqualToSerialized(v_field, &s_field)) {
                    return false;
                }
            }
            return true;
        },
        else => unsupportedType(T),
    }
}

/// Deserializes a value of type T from a byte buffer. Specifically, returns a pointer to a `Serialized(T)`,
/// aka a logically equivalent view of T. The lifetime of the returned pointer is tied to the lifetime of the
/// provided buffer, e.g. the buffer must outlive the returned pointer.
pub fn deserialize(comptime T: type, serialized: []const u8) *const Serialized(T) {
    return @ptrCast(@alignCast(serialized.ptr));
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
