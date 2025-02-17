// SPDX-License-Identifier: MIT

const Logger = @import("Logger.zig");
pub const Filter = @import("Filter.zig");
pub const Builder = @import("Builder.zig");
pub const Level = Filter.Level;
pub const defaultLevelEnabled = Logger.defaultLevelEnabled;
pub const levelEnabled = Logger.levelEnabled;

pub const SetupOptions = Logger.SetupOptions;
pub const setup = Logger.setup;
pub const setupWith = Logger.setupWith;
pub const setupFn = Logger.setupFn;

pub const InitOptions = Logger.InitOptions;
pub const init = Logger.init;
pub const tryInit = Logger.tryInit;

test "force analysis" {
    comptime {
        @import("std").testing.refAllDecls(@This());
        _ = Logger;
    }
}
