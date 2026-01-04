const builtin = @import("builtin");
const std = @import("std");
const platform = @import("gio_platform");
const kb = platform.memory.kb;
const mb = platform.memory.mb;
const gb = platform.memory.gb;

const arena_header_size: usize = 128;

pub const GioArenaFlags = packed struct {
    large_pages: bool = false,
    no_chain: bool = false,
};

pub const GioArenaParams = struct {
    flags: GioArenaFlags = .{},
    reserve_size: usize = mb(64),
    commit_size: usize = kb(64),
    optional_backing_buffer: ?*anyopaque = null,
};

const DebugInfo = struct {
    file: []const u8,
    line: u32,
    peak_used: usize,
};

pub const GioArenaError = error{
    OutOfMemory,
    InvalidAlignment,
    CapacityExceded,
    NotInitialized,
    Failure,
};

//TODO: fiz debug info cases
pub const GioArena = struct {
    const Self = @This();

    arena: ?*Self = null,
    current: ?*Self = null,
    prev: ?*Self = null,
    flags: GioArenaFlags,
    commit_size: usize,
    reserve_size: usize,
    global_offset: usize,
    local_offset: usize,
    reserved_bytes: usize,
    commited_bytes: usize,
    // debug_info: if (builtin.mode == .Debug and !builtin.is_test) DebugInfo else void,

    pub fn init(params: GioArenaParams) GioArenaError!*Self {
        var reserve_size: usize = params.reserve_size;
        var commit_size: usize = params.commit_size;

        if (params.flags.large_pages) {
            const large_page_size: usize = platform.memory.osGetLargePageSize();
            reserve_size = std.mem.alignForward(usize, reserve_size, large_page_size);
            commit_size = std.mem.alignForward(usize, commit_size, large_page_size);
        } else {
            const page_size: usize = platform.memory.osGetPageSize();
            reserve_size = std.mem.alignForward(usize, reserve_size, page_size);
            commit_size = std.mem.alignForward(usize, commit_size, page_size);
        }

        var base: ?*anyopaque = params.optional_backing_buffer;

        if (base == null) {
            //release the memory in case of error
            errdefer platform.memory.osRelease(base, reserve_size);

            if (params.flags.large_pages) {
                base = platform.memory.osReserveLarge(reserve_size) catch |err| {
                    std.log.err("Failed to allocate arena: reserved_size={}, error={}", .{ reserve_size, err });
                    return error.OutOfMemory;
                };
                // errdefer platform.memory.osRelease(base, reserve_size);

                _ = platform.memory.osCommitLarge(base, commit_size) catch |err| {
                    std.log.err("Failed to commmit arena: commit_size={}, error={}", .{ commit_size, err });
                    return error.OutOfMemory;
                };
            } else {
                base = platform.memory.osReserve(reserve_size) catch |err| {
                    std.log.err("Failed to allocate arena: reserved_size={}, error={}", .{ reserve_size, err });
                    return error.OutOfMemory;
                };
                // errdefer platform.memory.osRelease(base, reserve_size);

                _ = platform.memory.osCommit(base, commit_size) catch |err| {
                    std.log.err("Failed to allocate arena: commit_size={}, error={}", .{ commit_size, err });
                    return error.OutOfMemory;
                };
            }
        }

        const arena: *Self = @ptrCast(@alignCast(base));

        arena.current = arena;
        arena.prev = null;
        arena.flags = params.flags;
        arena.commit_size = commit_size;
        arena.reserve_size = reserve_size;
        arena.global_offset = 0;
        arena.local_offset = arena_header_size;
        arena.commited_bytes = commit_size;
        arena.reserved_bytes = reserve_size;

        // if (builtin.mode == .Debug and !builtin.is_test) {
        //     arena.debug_info.file = @src().file;
        //     arena.debug_info.line = @src().line;
        //     arena.debug_info.peak_used = 0;
        //     std.log.debug("Arena allocated: {}:{} (reserved: {} KB, {} commited: KB)", .{
        //         arena.debug_info.file, arena.debug_info.line, reserve_size / 1024, commit_size / 1024,
        //     });
        // }

        return arena;
    }

    pub fn deinit(self: *Self) void {
        // if (builtin.mode == .Debug and !builtin.is_test) {
        //     std.log.debug("Arena released: {}:{}d (peak used: {} KB)", .{
        //         self.debug_info.file, self.debug_info.line, self.debug_info.peak_used / 1024,
        //     });
        // }

        var current: ?*Self = self.current orelse {
            std.log.warn("deinit used with uninitialized {s}", .{@typeName(Self)});
            return;
        };

        while (current) |cur| {
            const prev: ?*Self = cur.prev;
            platform.memory.osRelease(cur, cur.reserved_bytes);

            current = prev;
        }
    }

    fn pushRaw(self: *Self, size: usize, alignment: usize, zero: bool) GioArenaError!*anyopaque {
        if (!std.math.isPowerOfTwo(alignment)) return error.InvalidAlignment;

        if (self.current) |cur| {
            var current: *Self = cur;
            var aligned_start: usize = std.mem.alignForward(
                usize,
                current.local_offset,
                alignment,
            );
            var aligned_end: usize = aligned_start + size;

            if (current.reserved_bytes < aligned_end) {
                if (current.flags.no_chain) {
                    std.log.warn("Chaining is disabled. You want to push {} bytes but you already commited {} which surpass the reserved size limit of {}.", .{ size, self.commited_bytes, self.reserved_bytes });
                    return error.CapacityExceded;
                } else {
                    var reserve_size: usize = current.reserve_size;
                    var commit_size: usize = current.commit_size;

                    if (size + arena_header_size > reserve_size) {
                        reserve_size = std.mem.alignForward(usize, size + arena_header_size, alignment);
                        commit_size = std.mem.alignForward(usize, size + arena_header_size, alignment);
                    }

                    var new_block: *Self = try init(.{
                        .flags = current.flags,
                        .reserve_size = reserve_size,
                        .commit_size = commit_size,
                    });

                    new_block.global_offset = current.global_offset + current.reserved_bytes;
                    new_block.prev = self.current;
                    self.current = new_block;
                    current = new_block;
                    aligned_start = std.mem.alignForward(usize, current.local_offset, alignment);
                    aligned_end = aligned_start + size;
                }
            }

            var size_to_zero: usize = 0;
            if (zero) {
                size_to_zero = @min(current.commited_bytes, aligned_end) - aligned_start;
            }

            if (current.commited_bytes < aligned_end) {
                var commit_target_aligned: usize = aligned_end + current.commit_size - 1;
                commit_target_aligned -= commit_target_aligned % current.commit_size;
                const commit_limit_clamped: usize = @min(commit_target_aligned, current.reserved_bytes);
                const bytes_to_commit: usize = commit_limit_clamped - current.commited_bytes;
                const ptr: [*]u8 = @ptrCast(current);
                const commit_ptr: *anyopaque = @ptrCast(ptr + current.commited_bytes);

                if (current.flags.large_pages) {
                    _ = platform.memory.osCommitLarge(commit_ptr, bytes_to_commit) catch return error.OutOfMemory;
                } else {
                    _ = platform.memory.osCommit(commit_ptr, bytes_to_commit) catch return error.OutOfMemory;
                }

                current.commited_bytes = commit_limit_clamped;

                std.log.debug("Arena auto-commit: +{} KB (total: {} KB)", .{
                    bytes_to_commit / 1024,
                    current.commited_bytes / 1024,
                });
            }

            if (current.commited_bytes >= aligned_end) {
                const ptr: [*]u8 = @ptrCast(current);
                const return_ptr: *anyopaque = @ptrCast(ptr + aligned_start);
                current.local_offset = aligned_end;

                if (size_to_zero != 0) {
                    @memset((ptr + aligned_start)[0..size_to_zero], 0);
                }
                return return_ptr;
            }
        }
        return error.Failure;
    }

    pub const PushOptions = struct {
        alignment: ?usize = null,
        zero: ?bool = false,
    };

    pub fn push(self: *Self, comptime T: type, options: PushOptions) GioArenaError!*T {
        errdefer |err| {
            std.log.warn("Failed to push {s}. Error: {}", .{ @typeName(T), err });
        }
        const alignment: usize = options.alignment orelse @alignOf(T);
        const size: usize = @sizeOf(T);
        const zero: bool = options.zero orelse false;

        return @ptrCast(@alignCast(try pushRaw(self, size, alignment, zero)));
    }

    pub fn pushArray(self: *Self, comptime T: type, count: usize, options: PushOptions) GioArenaError![]T {
        errdefer |err| {
            std.log.warn("Failed to push array of type {s} and size {}. Error {}", .{ @typeName(T), count, err });
        }
        const alignment: usize = options.alignment orelse @alignOf(T);
        const sizeOfT: usize = @sizeOf(T);
        const zero: bool = options.zero orelse false;
        //Overflow should'nt happen son on a 64 bit machine
        const size: usize = std.math.mul(usize, sizeOfT, count) catch unreachable;
        const raw = try pushRaw(self, size, alignment, zero);
        const ptr: [*]T = @ptrCast(@alignCast(raw));
        return ptr[0..count];
    }

    pub fn pos(self: *Self) usize {
        const current = self.current orelse {
            std.log.err("{s} was not initialized.", .{@typeName(Self)});
            unreachable;
        };
        return current.global_offset + current.local_offset;
    }

    fn popTo(self: *Self, in_pos: usize) void {
        const big_pos: usize = @max(arena_header_size, in_pos);
        var current: *Self = self.current orelse {
            std.log.err("{s} was not initialized.", .{@typeName(Self)});
            unreachable;
        };

        while (current.global_offset >= big_pos) {
            const prev: ?*Self = current.prev;
            platform.memory.osRelease(current, current.reserved_bytes);

            current = prev.?;
        }

        self.current = current;
        const new_pos: usize = big_pos - current.global_offset;
        if (new_pos > current.local_offset) unreachable;

        current.local_offset = new_pos;
    }

    pub fn clear(self: *Self) void {
        popTo(self, 0);
    }

    pub fn pop(self: *Self, amt: usize) void {
        const pos_old: usize = pos(self);
        const pos_new: usize = if (amt < pos_old) pos_old - amt else 0;
        popTo(self, pos_new);
    }
};

pub const GioArenaTemp = struct {
    const Self = @This();

    arena: *GioArena,
    pos: usize,

    pub fn init(arena: *GioArena) Self {
        const pos: usize = arena.pos();
        return .{
            .arena = arena,
            .pos = pos,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.popTo(self.pos);
    }
};

const testing = std.testing;
test "InitAndDeinit" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    try testing.expectEqual(arena.reserved_bytes, mb(64));
    try testing.expectEqual(arena.commit_size, kb(64));
    try testing.expectEqual(arena.local_offset, arena_header_size);
    try testing.expectEqual(arena.global_offset, 0);
    try testing.expectEqual(arena.current, arena);
    try testing.expectEqual(arena.prev, null);

    const pos = arena.pos();
    try testing.expectEqual(pos, arena_header_size);
}

test "BasicAllocation" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const value = try arena.push(usize, .{});
    var pos = arena.pos();

    var valueOffset = @sizeOf(usize) * 1 + arena_header_size;

    try testing.expectEqual(pos, valueOffset);

    try testing.expect(arena.commited_bytes != 0);

    value.* = 10;

    try testing.expectEqual(value.*, 10);

    const data = try arena.pushArray(f32, 1000, .{});
    try testing.expectEqual(data.len, 1000);
    pos = arena.pos();
    valueOffset += (@sizeOf(f32) * 1000);
    try testing.expectEqual(pos, valueOffset);
    data[0] = 1.0;
    data[999] = 999.0;
    try testing.expectEqual(data[0], 1.0);
    try testing.expectEqual(data[999], 999.0);
}

test "Alignment" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const p1: *u8 = try arena.push(u8, .{});
    try testing.expectEqual(@intFromPtr(p1) % @alignOf(u8), 0);

    const p2: *usize = try arena.push(usize, .{});
    try testing.expectEqual(@intFromPtr(p2) % @alignOf(usize), 0);

    const p3: *u8 = try arena.push(u8, .{});
    try testing.expectEqual(@intFromPtr(p3) % @alignOf(u8), 0);

    const Vec4 align(16) = struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32,
    };

    const p4: *Vec4 = try arena.push(Vec4, .{});
    try testing.expectEqual(@intFromPtr(p4) % @alignOf(Vec4), 0);
}

test "CommitOnDemand" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    try testing.expectEqual(arena.commited_bytes, kb(64));

    _ = try arena.pushRaw(kb(10), 16, false);
    try testing.expectEqual(arena.commited_bytes, kb(64));
    var pos = arena.pos();
    var acc: usize = kb(10) + arena_header_size;
    try testing.expectEqual(pos, acc);

    _ = try arena.pushRaw(kb(30), 16, false);
    try testing.expectEqual(arena.commited_bytes, kb(64));
    pos = arena.pos();
    acc += kb(30);
    try testing.expectEqual(pos, acc);

    _ = try arena.pushRaw(kb(50), 16, false);
    try testing.expectEqual(arena.commited_bytes, kb(128));
    pos = arena.pos();
    acc += kb(50);
    try testing.expectEqual(pos, acc);
}

test "LargeAllocation" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const large_block: *anyopaque = try arena.pushRaw(mb(10), 16, false);
    try testing.expect(arena.commited_bytes >= mb(10));

    const bytes: [*]u8 = @ptrCast(@alignCast(large_block));
    bytes[0] = 42;
    bytes[mb(10) - 1] = 84;
    try testing.expectEqual(bytes[0], 42);
    try testing.expectEqual(bytes[mb(10) - 1], 84);
}

test "ZeroInitialization" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const zeroed: []u8 = try arena.pushArray(u8, 1024, .{ .zero = true, .alignment = 16 });

    for (zeroed) |i| {
        try testing.expectEqual(i, 0);
    }
}

test "PositionAndPop" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const pos = arena.pos();
    try testing.expectEqual(pos, arena_header_size);

    _ = try arena.pushRaw(100, 16, false);
    const pos_p1 = arena.pos();
    try testing.expect(pos_p1 > pos);

    _ = try arena.pushRaw(100, 16, false);
    const pos_p2 = arena.pos();
    try testing.expect(pos_p2 > pos_p1);

    arena.pop(200);
    try testing.expect(arena.pos() < pos_p1 + 16);

    arena.popTo(pos);
    try testing.expectEqual(arena.pos(), pos);
}

test "ArenaClear" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(kb(10), 16, false);
    _ = try arena.pushRaw(kb(20), 16, false);
    _ = try arena.pushRaw(kb(30), 16, false);

    const pos_before_clear = arena.pos();
    const commited_before_clear = arena.commited_bytes;

    try testing.expect(pos_before_clear > arena_header_size);
    try testing.expect(commited_before_clear > 0);
    try testing.expectEqual(arena.local_offset, arena_header_size + kb(10 + 20 + 30));

    arena.clear();

    try testing.expectEqual(arena.pos(), arena_header_size);
    try testing.expectEqual(arena.commited_bytes, commited_before_clear);

    _ = try arena.pushRaw(1000, 16, false);
    try testing.expectEqual(arena.local_offset, arena_header_size + 1000);
}

test "TemporaryScope" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(1000, 16, false);
    const pos_before_temp = arena.pos();

    try testing.expectEqual(
        arena_header_size + 1000,
        pos_before_temp,
    );

    {
        var temp = GioArenaTemp.init(arena);
        defer temp.deinit();

        const expected1 =
            std.mem.alignForward(usize, pos_before_temp, 16) + 500;

        _ = try arena.pushRaw(500, 16, false);
        try testing.expectEqual(expected1, arena.pos());

        const expected2 =
            std.mem.alignForward(usize, expected1, 16) + 300;

        _ = try arena.pushRaw(300, 16, false);
        try testing.expectEqual(expected2, arena.pos());
    }

    try testing.expectEqual(arena.pos(), pos_before_temp);
    try testing.expectEqual(arena.local_offset, arena_header_size + 1000);
    try testing.expectEqual(arena.global_offset, 0);
}

test "MultiBlockChain" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(kb(900), 16, false);
    try testing.expectEqual(arena.current, arena);
    try testing.expectEqual(arena.current.?.prev, null);
    try testing.expectEqual(arena.current.?.global_offset, 0);

    _ = try arena.pushRaw(kb(200), 16, false);
    try testing.expect(arena.current != arena);
    try testing.expect(arena.current.?.prev != null);
    try testing.expectEqual(arena.current.?.prev, arena);
    try testing.expect(arena.current.?.global_offset > 0);

    try testing.expect(arena.pos() > mb(1));
}

test "NoChainFlag" {
    const arena = try GioArena.init(.{
        .flags = .{ .no_chain = true },
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(kb(900), 16, false);
    const result = arena.pushRaw(kb(200), 16, false);
    try testing.expectError(error.CapacityExceded, result);
}

test "SmokeTest" {
    for (0..100) |_| {
        const arena = try GioArena.init(.{
            .flags = .{},
            .reserve_size = mb(64),
            .commit_size = kb(64),
        });
        defer arena.deinit();

        _ = try arena.pushRaw(kb(100), 16, false);
    }
}

test "AllocationExactBoundaryNoChainShouldFail" {
    const arena = try GioArena.init(.{
        .flags = .{ .no_chain = true },
        .reserve_size = kb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(kb(64) - arena_header_size, 8, false);
    const result = arena.pushRaw(1, 8, false);
    try testing.expectError(error.CapacityExceded, result);
}

test "NestedTemporaryScopes" {
    const arena = try GioArena.init(.{
        .flags = .{ .no_chain = true },
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const root_pos = arena.pos();
    {
        var t1 = GioArenaTemp.init(arena);
        defer t1.deinit();
        {
            var t2 = GioArenaTemp.init(arena);
            defer t2.deinit();
            {
                var t3 = GioArenaTemp.init(arena);
                defer t3.deinit();
            }
        }
        try testing.expectEqual(root_pos, arena.pos());
    }
}

test "AlignmentStress" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(2),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    var alignment: usize = 1;
    while (alignment <= 64) : (alignment <<= 1) {
        const p = try arena.pushRaw(100, alignment, false);
        try testing.expectEqual(@intFromPtr(p) % alignment, 0);
    }
}

test "PopAccrossBlockBoundary" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(kb(900), 8, false);
    _ = try arena.pushRaw(kb(200), 8, false);

    const before_pop = arena.pos();
    arena.pop(kb(200));
    try testing.expect(before_pop > arena.pos());
}

test "NoChainBigAligned" {
    const arena = try GioArena.init(.{
        .flags = .{ .no_chain = true },
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    const result = arena.pushRaw(mb(2), 64, false);
    try testing.expectError(error.CapacityExceded, result);
}

test "InvalidAlignment" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = mb(1),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    try testing.expectError(error.InvalidAlignment, arena.pushRaw(16, 3, false));
}

test "PopMoreThanUsedClamps" {
    const arena = try GioArena.init(.{
        .flags = .{},
        .reserve_size = kb(64),
        .commit_size = kb(64),
    });
    defer arena.deinit();

    _ = try arena.pushRaw(100, 8, false);
    arena.pop(mb(1));

    try testing.expectEqual(arena.pos(), arena_header_size);
}
