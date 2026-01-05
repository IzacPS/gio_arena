//TODO: implement a callback to initialize itens on push and pushArray

const GioArenaImpl = @import("src/gio_arena_impl.zig");

pub const GioArena = GioArenaImpl.GioArena;

pub const GioArenaParams = GioArenaImpl.GioArenaParams;

pub const GioArenaFlags = GioArenaImpl.GioArenaFlags;

pub const GioArenaTemp = GioArenaImpl.GioArenaTemp;

pub const GioArenaError = GioArenaImpl.GioArenaError;

test {
    @import("std").testing.refAllDecls(@This());
}
