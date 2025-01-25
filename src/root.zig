// SPDX-License-Identifier: MIT

pub const Logger = @import("Logger.zig");
pub const LogLevel = Logger.InitOptions.LogLevel;
pub const level_enabled = Logger.level_enabled;
pub const set_log_level = Logger.set_log_level;

pub const SetupOptions = Logger.SetupOptions;
pub const setup = Logger.setup;
pub const setupWith = Logger.setupWith;
pub const setupFn = Logger.setupFn;

pub const InitOptions = Logger.InitOptions;
pub const init = Logger.init;
pub const try_init = Logger.try_init;

test "force analysis" {
    comptime {
        @import("std").testing.refAllDecls(@This());
    }
}
