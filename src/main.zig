const std = @import("std");
const config_mod = @import("config.zig");
const log_mod = @import("log.zig");

var shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn handleSigterm(_: c_int) callconv(.C) void {
    shutdown.store(true, .seq_cst);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();

    const cfg_path = args_iter.next() orelse {
        std.debug.print("usage: lumon <config.lua>\n", .{});
        std.process.exit(1);
    };

    var logger = log_mod.Logger.init(allocator, .info);
    defer logger.deinit();

    // Register signal handlers
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigterm },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    try std.posix.sigaction(std.posix.SIG.INT,  &act, null);

    // Load config
    const cfg_data = try std.fs.cwd().readFileAlloc(allocator, cfg_path, 1 * 1024 * 1024);
    defer allocator.free(cfg_data);

    var parser = config_mod.ConfigParser.init(allocator, cfg_data);
    const services = try parser.parse();
    defer allocator.free(services);

    logger.info("lumon", "loaded {} service(s) from {s}", .{ services.len, cfg_path });

    // Supervisor loop
    while (!shutdown.load(.seq_cst)) {
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    logger.info("lumon", "shutting down gracefully", .{});
}
