const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// Either a pointer to t, or a value of U
pub fn EitherPtr(comptime PtrT: type, comptime U: type) type {
    const T = getPtrType(PtrT);

    return packed struct {
        const Self = @This();

        value: usize,

        // Use the least significant bit to distinguish pointer vs value
        const IS_VALUE_BIT: usize = 1;
        const PTR_MASK: usize = ~IS_VALUE_BIT;

        // Whether PtrT is optional
        const IS_OPTIONAL = isOptional(PtrT);

        // Compile-time validation
        comptime {
            const max_value_bits = @bitSizeOf(usize) - 1; // Reserve 1 bit for discriminator

            const value_bits_needed = @bitSizeOf(U);

            if (value_bits_needed > max_value_bits) {
                @compileError(std.fmt.comptimePrint("Value type requires {} bits but only {} bits available", .{ value_bits_needed, max_value_bits }));
            }

            // Ensure pointer type has sufficient alignment
            if (@alignOf(T) < 2) {
                @compileError("Pointer type '" ++ @typeName(T) ++ "' must have at least 2-byte alignment to use EitherPtr");
            }
        }

        pub const Union = union(enum) {
            ptr: PtrT,
            value: U,
        };

        pub fn fromValue(value: usize) Self {
            return Self{ .value = value };
        }

        pub fn initPtr(ptr: PtrT) Self {
            if (IS_OPTIONAL) {
                // Handle optional pointer
                if (ptr) |actual_ptr| {
                    const ptr_int = @intFromPtr(actual_ptr);
                    assert((ptr_int & IS_VALUE_BIT) == 0); // Pointer must be aligned
                    return Self{ .value = ptr_int };
                } else {
                    // Null pointer - store 0 (which has IS_VALUE_BIT = 0, so isPtr() returns true)
                    return Self{ .value = 0 };
                }
            } else {
                // Handle regular pointer
                const ptr_int = @intFromPtr(ptr);
                assert((ptr_int & IS_VALUE_BIT) == 0); // Pointer must be aligned
                return Self{ .value = ptr_int };
            }
        }

        pub fn initValue(val: U) Self {
            const val_int = toInt(U, val);
            // Shift value left by 1 bit and set the IS_VALUE_BIT
            return Self{ .value = (val_int << 1) | IS_VALUE_BIT };
        }

        pub fn isPtr(self: Self) bool {
            return (self.value & IS_VALUE_BIT) == 0;
        }

        pub fn toInner(self: Self) usize {
            return self.value;
        }

        pub fn isValue(self: Self) bool {
            return (self.value & IS_VALUE_BIT) != 0;
        }

        // Pointer can be null if PtrT is optional
        pub fn getPtr(self: Self) PtrT {
            assert(self.isPtr());
            const ptr_bits = self.value & PTR_MASK;

            if (IS_OPTIONAL) {
                if (ptr_bits == 0) {
                    return null;
                } else {
                    return @ptrFromInt(ptr_bits);
                }
            } else {
                return @ptrFromInt(ptr_bits);
            }
        }

        pub fn getValue(self: Self) U {
            assert(self.isValue());
            // Shift right by 1 bit to get the original value
            return fromInt(U, self.value >> 1);
        }

        pub fn asPtr(self: Self) ?*T {
            if (self.isPtr()) return self.getPtr();
            return null;
        }

        pub fn asValue(self: Self) ?U {
            if (self.isValue()) return self.getValue();
            return null;
        }

        pub fn asUnion(self: Self) Union {
            if (self.isPtr()) return .{ .ptr = self.getPtr() };
            return .{ .value = self.getValue() };
        }
    };
}

/// Compile-time calculation of required bits for a value
fn bitsRequired(comptime max_value: usize) comptime_int {
    if (max_value == 0) return 0;
    return @bitSizeOf(usize) - @clz(max_value);
}

/// Get alignment bits available for packing
fn getAlignmentBits(comptime T: type) usize {
    const alignment: usize = @alignOf(T);
    if (alignment <= 1) return 0;
    return @ctz(alignment);
}

fn getHighBitsAvailable() usize {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => 16, // x86-64 uses 48-bit addresses, top 16 bits unused
        .aarch64 => 8, // ARM64 commonly uses 56-bit addresses
        else => 0, // Conservative for other architectures
    };
}

/// Check if a tag can be packed with a pointer type at compile time
pub fn CanPack(comptime T: type, bits_needed: usize) bool {
    const alignment_bits_local = getAlignmentBits(T);
    const high_bits_available = getHighBitsAvailable();

    // Calculate total available bits using hybrid approach
    const total_available_bits = alignment_bits_local + high_bits_available;

    // Check if tag fits in available bits
    return bits_needed <= total_available_bits;
}

pub fn MaxTagBits(comptime T: type) comptime_int {
    const alignment_bits_local = getAlignmentBits(T);
    const high_bits_available = getHighBitsAvailable();

    return alignment_bits_local + high_bits_available;
}

/// Determine optimal packing strategy at compile time
fn PackingStrategy(comptime T: type, comptime Tag: type) type {
    const tag_bits_needed = @bitSizeOf(Tag);

    const alignment_bits_local = getAlignmentBits(T);
    const high_bits_available = getHighBitsAvailable();

    // Calculate total available bits using hybrid approach
    const total_available_bits = alignment_bits_local + high_bits_available;

    if (tag_bits_needed > total_available_bits) {
        @compileError(std.fmt.comptimePrint("Tag requires {} bits but only {} bits available (alignment: {} + high bits: {}). " ++
            "Consider using a smaller tag type or separate storage.", .{ tag_bits_needed, total_available_bits, alignment_bits_local, high_bits_available }));
    }

    return struct {
        pub const tag_bits = tag_bits_needed;
        pub const alignment_bits = alignment_bits_local;
        pub const high_bits = high_bits_available;
        pub const total_bits = total_available_bits;

        // Strategy selection - now with hybrid approach
        pub const can_use_alignment_only = alignment_bits >= tag_bits_needed;
        pub const can_use_high_only = high_bits_available >= tag_bits_needed;
        pub const can_use_packed = total_available_bits >= tag_bits_needed;

        // Preferred strategy (in order of efficiency)
        pub const strategy = if (can_use_alignment_only)
            PackingMethod.Alignment
        else if (can_use_high_only)
            PackingMethod.HighBits
        else if (can_use_packed)
            PackingMethod.Packed
        else
            @compileError(std.fmt.comptimePrint("Tag requires {} bits but only {} bits available (alignment: {} + high bits: {}). " ++
                "Consider using a smaller tag type or separate storage.", .{ tag_bits_needed, total_available_bits, alignment_bits_local, high_bits_available }));
    };
}

const PackingMethod = enum {
    Alignment, // Pack in low alignment bits
    HighBits, // Pack in high unused address bits
    Packed, // Pointer in low
};

pub fn TaggedPtr(comptime PtrT: type, comptime Tag: type) type {
    const T = getPtrType(PtrT);
    const strategy = PackingStrategy(T, Tag);

    return struct {
        const Self = @This();

        // Storage based on optimal strategy
        value: usize,

        // Compile-time constants
        const PACKING_METHOD = strategy.strategy;
        const TAG_BITS: usize = strategy.tag_bits;
        const ALIGNMENT_BITS = strategy.alignment_bits;
        const HIGH_BITS = strategy.high_bits;

        // Whether PtrT is optional
        const IS_OPTIONAL = isOptional(PtrT);

        // Masks and shifts for different packing methods
        const LOW_TAG_BITS = @min(TAG_BITS, ALIGNMENT_BITS);
        const HIGH_TAG_BITS = TAG_BITS;

        const LOW_TAG_MASK = (@as(usize, 1) << LOW_TAG_BITS) - 1;
        const HIGH_TAG_MASK = (@as(usize, 1) << HIGH_TAG_BITS) - 1;
        const HIGH_TAG_SHIFT = @bitSizeOf(usize) - HIGH_TAG_BITS;

        const PTR_BITS = @bitSizeOf(usize) - ALIGNMENT_BITS - HIGH_BITS;

        const PTR_MASK = switch (PACKING_METHOD) {
            .Alignment => ~LOW_TAG_MASK,
            .HighBits, .Packed => (@as(usize, 1) << (@bitSizeOf(usize) - HIGH_BITS)) - 1,
        };

        pub fn init(ptr: PtrT, tag: Tag) Self {
            const ptr_int = switch (IS_OPTIONAL) {
                true => if (ptr == null) 0 else @intFromPtr(ptr),
                false => @intFromPtr(ptr),
            };

            const tag_int = toInt(Tag, tag);

            // Validate alignment requirements
            if (PACKING_METHOD == .Alignment or PACKING_METHOD == .Packed) {
                assert((ptr_int & LOW_TAG_MASK) == 0); // Pointer must be aligned
            }

            const value = switch (PACKING_METHOD) {
                .Alignment => ptr_int | tag_int,
                .HighBits => ptr_int | (tag_int << HIGH_TAG_SHIFT),
                .Packed => (ptr_int >> ALIGNMENT_BITS) | (tag_int << PTR_BITS),
            };

            return Self{ .value = value };
        }

        pub fn getPtr(self: Self) PtrT {
            const ptr_bits = switch (PACKING_METHOD) {
                .Alignment => self.value & PTR_MASK,
                .HighBits => self.value & PTR_MASK,
                .Packed => (self.value << ALIGNMENT_BITS) & PTR_MASK,
            };

            if (IS_OPTIONAL) {
                if (ptr_bits == 0) {
                    return null;
                } else {
                    return @ptrFromInt(ptr_bits);
                }
            } else {
                return @ptrFromInt(ptr_bits);
            }
        }

        pub fn getTag(self: Self) Tag {
            const tag_bits = switch (PACKING_METHOD) {
                .Alignment => self.value & LOW_TAG_MASK,
                .HighBits => (self.value >> HIGH_TAG_SHIFT) & HIGH_TAG_MASK,
                .Packed => (self.value >> PTR_BITS),
            };
            return fromInt(Tag, tag_bits);
        }

        pub fn setPtr(self: *Self, ptr: PtrT) void {
            const tag = self.getTag();
            self.* = Self.init(ptr, tag);
        }

        pub fn setTag(self: *Self, tag: Tag) void {
            const ptr = self.getPtr();
            self.* = Self.init(ptr, tag);
        }

        pub fn getPackingInfo() type {
            return struct {
                pub const method = PACKING_METHOD;
                pub const tag_bits = TAG_BITS;
                pub const alignment_bits = ALIGNMENT_BITS;
                pub const high_bits = HIGH_BITS;
                pub const low_tag_bits = if (PACKING_METHOD == .Packed) LOW_TAG_BITS else if (PACKING_METHOD == .Alignment) TAG_BITS else 0;
                pub const high_tag_bits = if (PACKING_METHOD == .Packed) HIGH_TAG_BITS else if (PACKING_METHOD == .HighBits) TAG_BITS else 0;
                pub const max_tag_value = (@as(usize, 1) << TAG_BITS) - 1;
            };
        }
    };
}

// Utility functions for tag conversion
fn toInt(comptime T: type, tag: T) usize {
    return switch (@typeInfo(T)) {
        .void => 0,
        .int => @intCast(tag),
        .@"enum" => @intFromEnum(tag),
        .bool => @intFromBool(tag),
        .@"struct" => |struct_info| blk: {
            if (struct_info.backing_integer) |BackingInteger| {
                break :blk @as(usize, @bitCast(@as(BackingInteger, @bitCast(tag))));
            } else {
                @compileError("Tag struct '" ++ @typeName(T) ++ "' must be a packed struct with a backing integer type");
            }
        },
        else => @compileError("Tag type '" ++ @typeName(T) ++ "' must be integer, enum, bool, or packed struct"),
    };
}

fn fromInt(comptime T: type, int_val: usize) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int => @intCast(int_val),
        .@"enum" => @enumFromInt(int_val),
        .bool => int_val != 0,
        .@"struct" => |struct_info| {
            if (struct_info.backing_integer) |BackingInteger| {
                return @as(T, @bitCast(@as(BackingInteger, @intCast(int_val))));
            } else {
                @compileError("Tag struct '" ++ @typeName(T) ++ "' must be a packed struct with a backing integer type");
            }
        },
        else => @compileError("Tag type '" ++ @typeName(T) ++ "' must be integer, enum, bool, or packed struct"),
    };
}

fn getPtrType(comptime PtrT: type) type {
    return switch (@typeInfo(PtrT)) {
        .pointer => |pointer_info| pointer_info.child,
        .optional => |optional_info| {
            const child_type_info = @typeInfo(optional_info.child);
            if (child_type_info != .pointer) {
                @compileError("Optional type '" ++ @typeName(PtrT) ++ "' must be an optional pointer type");
            }

            return child_type_info.pointer.child;
        },
        else => @compileError("Pointer type '" ++ @typeName(PtrT) ++ "' must be a pointer or optional pointer type"),
    };
}

fn isOptional(comptime PtrT: type) bool {
    return switch (@typeInfo(PtrT)) {
        .optional => true,
        else => false,
    };
}

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

test "TaggedPtr: all ones tag doesn't corrupt pointer" {
    const TestStruct = struct { value: u32 };
    var test_data = TestStruct{ .value = 0x12345678 };
    const ptr = &test_data;

    inline for (1..MaxTagBits(TestStruct) + 1) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(*TestStruct, TagType);

        // Create tag with all 1s for this bit width
        const all_ones_tag: TagType = (@as(usize, 1) << bit_width) - 1;

        const tagged_ptr = TaggedPtrType.init(ptr, all_ones_tag);
        const retrieved_ptr = tagged_ptr.getPtr();
        const retrieved_tag = tagged_ptr.getTag();

        try expectEqual(ptr, retrieved_ptr);
        try expectEqual(all_ones_tag, retrieved_tag);
        try expectEqual(@as(u32, 0x12345678), retrieved_ptr.value);
    }
}

test "EitherPtr: all ones value doesn't corrupt pointer detection" {
    const TestStruct = struct { value: u32 };
    var test_data = TestStruct{ .value = 0x87654321 };
    const ptr = &test_data;

    inline for (1..@bitSizeOf(usize)) |bit_width| {
        const ValueType = std.meta.Int(.unsigned, bit_width);
        const EitherPtrType = EitherPtr(*TestStruct, ValueType);

        const either_ptr = EitherPtrType.initPtr(ptr);
        try expect(either_ptr.isPtr());
        try expect(!either_ptr.isValue());
        try expectEqual(ptr, either_ptr.getPtr());

        // Test with all ones value
        const all_ones_value: ValueType = (@as(usize, 1) << bit_width) - 1;
        const either_val = EitherPtrType.initValue(all_ones_value);
        try expect(!either_val.isPtr());
        try expect(either_val.isValue());
        try expectEqual(all_ones_value, either_val.getValue());
    }
}

test "TaggedPtr: stress test with 2^20 values" {
    const TestStruct = struct { value: u64 };
    var test_data = TestStruct{ .value = 0xDEADBEEFCAFEBABE };
    const ptr = &test_data;

    const test_iterations = 1 << 20; // 2^20 iterations

    // Test different tag bit widths
    inline for (1..MaxTagBits(TestStruct) + 1) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(*TestStruct, TagType);
        const max_tag_value = (@as(usize, 1) << bit_width) - 1;

        const iterations = @min(max_tag_value + 1, test_iterations);
        const step = if (max_tag_value + 1 > test_iterations)
            (max_tag_value + 1) / test_iterations
        else
            1;

        var i: usize = 0;
        var tag_value: usize = 0;
        while (i < iterations) : (i += 1) {
            const tag: TagType = @intCast(tag_value);

            const tagged_ptr = TaggedPtrType.init(ptr, tag);
            const retrieved_ptr = tagged_ptr.getPtr();
            const retrieved_tag = tagged_ptr.getTag();

            try expectEqual(ptr, retrieved_ptr);
            try expectEqual(tag, retrieved_tag);

            // Verify the underlying data is unchanged
            try expectEqual(@as(u64, 0xDEADBEEFCAFEBABE), retrieved_ptr.value);

            tag_value += step;
            if (tag_value > max_tag_value) tag_value = max_tag_value;
        }
    }
}

test "EitherPtr: stress test with 2^20 values" {
    const TestStruct = struct { value: i32 };
    var test_data = TestStruct{ .value = -12345 };
    const ptr = &test_data;

    const test_iterations = 1 << 20; // 2^20 iterations

    // Test different value bit widths
    inline for (1..@bitSizeOf(usize)) |bit_width| {
        const ValueType = std.meta.Int(.unsigned, bit_width);
        const EitherPtrType = EitherPtr(*TestStruct, ValueType);
        const max_value = (@as(usize, 1) << bit_width) - 1;

        const iterations = @min(max_value + 1, test_iterations);
        const step = if (max_value + 1 > test_iterations)
            (max_value + 1) / test_iterations
        else
            1;

        std.log.info("iterations: {d}, step: {d}", .{ iterations, step });

        var i: usize = 0;
        var value_counter: usize = 0;
        while (i < iterations) : (i += 1) {
            // Test pointer variant every other iteration
            if (i % 2 == 0) {
                const either_ptr = EitherPtrType.initPtr(ptr);
                try expect(either_ptr.isPtr());
                try expectEqual(ptr, either_ptr.getPtr());
                try expectEqual(@as(i32, -12345), either_ptr.getPtr().value);
            } else {
                // Test value variant
                const value: ValueType = @intCast(value_counter);

                const either_val = EitherPtrType.initValue(value);
                try expect(either_val.isValue());
                try expectEqual(value, either_val.getValue());

                value_counter += step;
                if (value_counter > max_value) value_counter = max_value;
            }
        }
    }
}

test "TaggedPtr: boundary value tests" {
    const TestStruct = struct { data: u64 };
    var test_data = TestStruct{ .data = 0 };
    const ptr = &test_data;

    inline for (1..MaxTagBits(TestStruct) + 1) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(*TestStruct, TagType);
        const max_tag = std.math.maxInt(TagType);

        // Test boundary values: 0, 1, max-1, max
        const boundary_values = [_]TagType{ 0, 1, max_tag - 1, max_tag };

        for (boundary_values) |tag_val| {
            if (tag_val > max_tag) continue;

            const tagged_ptr = TaggedPtrType.init(ptr, tag_val);
            try expectEqual(ptr, tagged_ptr.getPtr());
            try expectEqual(tag_val, tagged_ptr.getTag());
        }

        // Test power-of-2 values
        inline for (0..bit_width) |power| {
            const pow2_val: TagType = @as(TagType, 1) << power;
            const tagged_ptr = TaggedPtrType.init(ptr, pow2_val);
            try expectEqual(ptr, tagged_ptr.getPtr());
            try expectEqual(pow2_val, tagged_ptr.getTag());
        }
    }
}

test "EitherPtr: boundary value tests" {
    const TestStruct = struct { x: f64, y: f64 };
    var test_data = TestStruct{ .x = 3.14159, .y = 2.71828 };
    const ptr = &test_data;

    inline for (1..@bitSizeOf(usize)) |bit_width| {
        const ValueType = std.meta.Int(.unsigned, bit_width);
        const EitherPtrType = EitherPtr(*TestStruct, ValueType);
        const max_val = std.math.maxInt(ValueType);

        // Test boundary values for value variant
        const boundary_values = [_]ValueType{ 0, 1, max_val - 1, max_val };

        for (boundary_values) |val| {
            if (val > max_val) continue;

            const either_val = EitherPtrType.initValue(val);
            try expect(either_val.isValue());
            try expectEqual(val, either_val.getValue());
        }

        // Test pointer variant
        const either_ptr = EitherPtrType.initPtr(ptr);
        try expect(either_ptr.isPtr());
        try expectEqual(ptr, either_ptr.getPtr());
        try expectEqual(@as(f64, 3.14159), either_ptr.getPtr().x);
    }
}

test "TaggedPtr: setPtr and setTag operations" {
    const TestStruct = struct { id: u32 };
    var test_data1 = TestStruct{ .id = 100 };
    var test_data2 = TestStruct{ .id = 200 };
    const ptr1 = &test_data1;
    const ptr2 = &test_data2;

    inline for (1..MaxTagBits(TestStruct) + 1) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(*TestStruct, TagType);
        const max_tag = std.math.maxInt(TagType);

        var tagged_ptr = TaggedPtrType.init(ptr1, 0);

        // Test setTag
        const new_tag = max_tag / 2;
        tagged_ptr.setTag(new_tag);
        try expectEqual(ptr1, tagged_ptr.getPtr());
        try expectEqual(new_tag, tagged_ptr.getTag());

        // Test setPtr
        tagged_ptr.setPtr(ptr2);
        try expectEqual(ptr2, tagged_ptr.getPtr());
        try expectEqual(new_tag, tagged_ptr.getTag());
        try expectEqual(@as(u32, 200), tagged_ptr.getPtr().id);
    }
}

test "EitherPtr: union conversion tests" {
    const TestStruct = struct { data: u64 };
    var test_data = TestStruct{ .data = 0x123456789ABCDEF0 };
    const ptr = &test_data;

    inline for (1..@bitSizeOf(usize)) |bit_width| {
        const ValueType = std.meta.Int(.unsigned, bit_width);
        const EitherPtrType = EitherPtr(*TestStruct, ValueType);
        const mid_value = (@as(ValueType, 1) << (bit_width - 1));

        // Test pointer to union conversion
        const either_ptr = EitherPtrType.initPtr(ptr);
        const ptr_union = either_ptr.asUnion();
        switch (ptr_union) {
            .ptr => |p| try expectEqual(ptr, p),
            .value => unreachable,
        }

        // Test value to union conversion
        const either_val = EitherPtrType.initValue(mid_value);
        const val_union = either_val.asUnion();
        switch (val_union) {
            .ptr => unreachable,
            .value => |v| try expectEqual(mid_value, v),
        }

        // Test asPtr and asValue methods
        try expectEqual(ptr, either_ptr.asPtr());
        try expectEqual(@as(?ValueType, null), either_ptr.asValue());
        try expectEqual(@as(?*TestStruct, null), either_val.asPtr());
        try expectEqual(mid_value, either_val.asValue().?);
    }
}

test "TaggedPtr: optional pointer support" {
    const TestStruct = struct { value: i16 };
    var test_data = TestStruct{ .value = -999 };
    const ptr: *TestStruct = &test_data;
    const null_ptr: ?*TestStruct = null;

    inline for (1..MaxTagBits(TestStruct)) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(?*TestStruct, TagType);
        const test_tag: TagType = (@as(TagType, 1) << (bit_width - 1)) - 1;

        // Test with non-null pointer
        const tagged_ptr = TaggedPtrType.init(ptr, test_tag);
        try expectEqual(ptr, tagged_ptr.getPtr().?);
        try expectEqual(test_tag, tagged_ptr.getTag());

        // Test with null pointer
        const tagged_null = TaggedPtrType.init(null_ptr, test_tag);
        try expectEqual(@as(?*TestStruct, null), tagged_null.getPtr());
        try expectEqual(test_tag, tagged_null.getTag());
    }
}

test "EitherPtr: zero value edge cases" {
    const TestStruct = struct { flag: u32 };
    var test_data = TestStruct{ .flag = 1 };
    const ptr = &test_data;

    inline for (1..@bitSizeOf(usize)) |bit_width| {
        const ValueType = std.meta.Int(.unsigned, bit_width);
        const EitherPtrType = EitherPtr(*TestStruct, ValueType);

        // Test zero value
        const either_zero = EitherPtrType.initValue(0);
        try expect(either_zero.isValue());
        try expect(!either_zero.isPtr());
        try expectEqual(@as(ValueType, 0), either_zero.getValue());

        // Test fromValue constructor
        const raw_value = either_zero.toInner();
        const reconstructed = EitherPtrType.fromValue(raw_value);
        try expect(reconstructed.isValue());
        try expectEqual(@as(ValueType, 0), reconstructed.getValue());

        // Ensure zero value doesn't interfere with pointer detection
        const either_ptr = EitherPtrType.initPtr(ptr);
        try expect(either_ptr.isPtr());
        try expect(either_ptr.toInner() != raw_value); // Different internal representation
    }
}

test "TaggedPtr: packing strategy verification" {
    const TestStruct = struct { data: u64 };

    inline for (1..MaxTagBits(*TestStruct) + 1) |bit_width| {
        const TagType = std.meta.Int(.unsigned, bit_width);
        const TaggedPtrType = TaggedPtr(*TestStruct, TagType);

        // Get packing info
        const PackingInfo = TaggedPtrType.getPackingInfo();

        // Verify the packing strategy makes sense
        try expect(PackingInfo.tag_bits == bit_width);
        try expect(PackingInfo.max_tag_value == (@as(usize, 1) << bit_width) - 1);

        // Verify that we can actually store the maximum tag value
        var test_data = TestStruct{ .data = 0x123456789ABCDEF0 };
        const ptr = &test_data;
        const max_tag: TagType = @intCast(PackingInfo.max_tag_value);

        const tagged_ptr = TaggedPtrType.init(ptr, max_tag);
        try expectEqual(ptr, tagged_ptr.getPtr());
        try expectEqual(max_tag, tagged_ptr.getTag());
    }
}

test "EitherPtr: pointer with enum tags of varying bit widths" {
    const Data = struct { id: u64 };

    // Test with different enum underlying types
    inline for (2..@bitSizeOf(usize)) |bit_width| {
        const IntType = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bit_width } });

        // Create enum with the specified underlying type
        const EnumType = @Type(.{
            .@"enum" = .{
                .tag_type = IntType,
                .fields = &[_]std.builtin.Type.EnumField{
                    .{ .name = "First", .value = 0 },
                    .{ .name = "Second", .value = 1 },
                    .{ .name = "Last", .value = std.math.maxInt(IntType) },
                },
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = false,
            },
        });

        const EitherEnum = EitherPtr(*Data, EnumType);

        var data = Data{ .id = 0x123456789ABCDEF0 };

        // Test pointer case
        const either_ptr = EitherEnum.initPtr(&data);
        try testing.expect(either_ptr.isPtr());
        try testing.expect(!either_ptr.isValue());
        try testing.expectEqual(either_ptr.getPtr().id, 0x123456789ABCDEF0);
        try testing.expectEqual(either_ptr.asPtr().?.id, 0x123456789ABCDEF0);
        try testing.expectEqual(either_ptr.asValue(), null);

        // Test enum value cases
        const either_first = EitherEnum.initValue(.First);
        try testing.expect(!either_first.isPtr());
        try testing.expect(either_first.isValue());
        try testing.expectEqual(either_first.getValue(), .First);
        try testing.expectEqual(either_first.asValue().?, .First);
        try testing.expectEqual(either_first.asPtr(), null);

        const either_second = EitherEnum.initValue(.Second);
        try testing.expect(either_second.isValue());
        try testing.expectEqual(either_second.getValue(), .Second);

        const either_last = EitherEnum.initValue(.Last);
        try testing.expect(either_last.isValue());
        try testing.expectEqual(either_last.getValue(), .Last);
    }
}

test "TaggedPtr: pointer with enum tags of varying bit widths" {
    const Data = struct {
        value: i32,
        padding: [7]u8, // Ensure good alignment
    };

    // Test with different enum underlying types
    inline for (2..MaxTagBits(*Data)) |bit_width| {
        const IntType = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bit_width } });

        // Create enum with the specified underlying type
        const EnumType = @Type(.{
            .@"enum" = .{
                .tag_type = IntType,
                .fields = &[_]std.builtin.Type.EnumField{
                    .{ .name = "Zero", .value = 0 },
                    .{ .name = "One", .value = 1 },
                    .{ .name = "Max", .value = std.math.maxInt(IntType) },
                },
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_exhaustive = false,
            },
        });

        const TaggedEnum = TaggedPtr(*Data, EnumType);

        var data = Data{ .value = 42, .padding = [_]u8{0} ** 7 };

        // Test with different enum values
        const tagged_zero = TaggedEnum.init(&data, .Zero);
        try testing.expectEqual(tagged_zero.getPtr().value, 42);
        try testing.expectEqual(tagged_zero.getTag(), .Zero);

        const tagged_one = TaggedEnum.init(&data, .One);
        try testing.expectEqual(tagged_one.getPtr().value, 42);
        try testing.expectEqual(tagged_one.getTag(), .One);

        const tagged_max = TaggedEnum.init(&data, .Max);
        try testing.expectEqual(tagged_max.getPtr().value, 42);
        try testing.expectEqual(tagged_max.getTag(), .Max);

        // Test setTag functionality
        var mutable_tagged = TaggedEnum.init(&data, .Zero);
        mutable_tagged.setTag(.Max);
        try testing.expectEqual(mutable_tagged.getTag(), .Max);
        try testing.expectEqual(mutable_tagged.getPtr().value, 42); // Pointer unchanged

        // Test setPtr functionality
        var other_data = Data{ .value = 123, .padding = [_]u8{0xFF} ** 7 };
        mutable_tagged.setPtr(&other_data);
        try testing.expectEqual(mutable_tagged.getPtr().value, 123);
        try testing.expectEqual(mutable_tagged.getTag(), .Max); // Tag unchanged
    }
}
