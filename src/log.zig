const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn str(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info  => "INFO ",
            .warn  => "WARN ",
            .err   => "ERROR",
        };
    }
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    level:     Level,
    file:      ?std.fs.File,
    path:      ?[]const u8,
    max_bytes: usize,
    written:   usize,
    mutex:     std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, level: Level) Logger {
        return .{
            .allocator = allocator,
            .level     = level,
            .file      = null,
            .path      = null,
            .max_bytes = 10 * 1024 * 1024, // 10 MiB default
            .written   = 0,
            .mutex     = .{},
        };
    }

    pub fn openFile(self: *Logger, path: []const u8, max_bytes: usize) !void {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
        self.file = f;
        self.path = try self.allocator.dupe(u8, path);
        self.max_bytes = max_bytes;
        // Seek to end so we append
        try f.seekFromEnd(0);
        self.written = try f.getPos();
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| f.close();
        if (self.path) |p| self.allocator.free(p);
    }

    pub fn log(self: *Logger, level: Level, service: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const ts = std.time.milliTimestamp();
        const secs = @divTrunc(ts, 1000);
        const ms   = @mod(ts, 1000);

        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(buf[0..], fmt, args) catch "<fmt error>";

        const line = std.fmt.allocPrint(self.allocator,
            "{d}.{d:0>3} [{s}] [{s}] {s}\n",
            .{ secs, ms, level.str(), service, msg }
        ) catch return;
        defer self.allocator.free(line);

        // Check rotation
        if (self.file != null and self.written + line.len > self.max_bytes) {
            self.rotate() catch {};
        }

        const dest = if (self.file) |f| f.writer() else std.io.getStdErr().writer();
        dest.writeAll(line) catch {};
        self.written += line.len;
    }

    // rotate: rename current log to .1 and open a fresh file
fn rotate(self: *Logger) !void {
        const path = self.path orelse return;
        if (self.file) |f| f.close();

        // Rename current log to .1
        const rotated = try std.fmt.allocPrint(self.allocator, "{s}.1", .{path});
        defer self.allocator.free(rotated);

        std.fs.cwd().rename(path, rotated) catch {};

        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        self.file = f;
        self.written = 0;
    }

    pub fn debug(self: *Logger, service: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, service, fmt, args);
    }
    pub fn info(self: *Logger, service: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, service, fmt, args);
    }
    pub fn warn(self: *Logger, service: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, service, fmt, args);
    }
    pub fn err(self: *Logger, service: []const u8, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, service, fmt, args);
    }
};
// mutex covers allocPrint + writeAll together to keep log lines from interleaving
// rotate(): self.written is reset to 0 after the new file is opened
// bufPrint: on format error the literal string "<fmt error>" is used as the message
// max_bytes default: 10 MiB (10 * 1024 * 1024); override via openFile max_bytes param
// Logger.log is safe to call from multiple threads; mutex serializes format + write
// env vars from config are stored in StringArrayHashMap; iteration order is insertion order
