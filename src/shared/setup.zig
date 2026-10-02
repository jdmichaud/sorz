//! What the screens before play decide for the game that follows, kept from power-on to power-on
//! (the original keeps it in its memory; it has no saves, decision D2): the options' values, the
//! players and their characters. It is part of the game's canonical state.
const std = @import("std");

pub const Players = enum(u8) { one, two };

pub const Setup = struct {
    /// The game menu's choice: one or two players.
    players: Players = .one,
};
