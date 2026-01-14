const std = @import("std");
const proc = @import("process.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();

    const cfg_path = args_iter.next() orelse {
        std.debug.print("usage: lumon <config>\n", .{});
        return;
    };
    _ = cfg_path;
    std.debug.print("[lumon] starting...\n", .{});
}
