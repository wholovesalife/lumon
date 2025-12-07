const std = @import("std");

pub const ProcessState = enum { stopped, starting, running, stopping, crashed, failed };

pub const RestartPolicy = enum {
    always, on_failure, never,
    pub fn parse(s: []const u8) !RestartPolicy {
        if (std.mem.eql(u8, s, "always"))     return .always;
        if (std.mem.eql(u8, s, "on-failure") or std.mem.eql(u8, s, "on_failure")) return .on_failure;
        if (std.mem.eql(u8, s, "never"))      return .never;
        return error.InvalidPolicy;
    }
};

pub const Process = struct {
    allocator:     std.mem.Allocator,
    name:          []const u8,
    cmd:           []const u8,
    args:          [][]const u8,
    restart:       RestartPolicy,
    max_restarts:  ?u32,
    state:         ProcessState,
    child:         ?std.process.Child,
    restart_count: u32,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, cmd: []const u8, args: [][]const u8, policy: RestartPolicy, max: ?u32) Process {
        return .{
            .allocator     = allocator,
            .name          = name,
            .cmd           = cmd,
            .args          = args,
            .restart       = policy,
            .max_restarts  = max,
            .state         = .stopped,
            .child         = null,
            .restart_count = 0,
        };
    }

    pub fn start(self: *Process) !void {
        self.state = .starting;
        const argv_len = 1 + self.args.len;
        var argv = try self.allocator.alloc([]const u8, argv_len);
        defer self.allocator.free(argv);
        argv[0] = self.cmd;
        for (self.args, 0..) |a, i| argv[i + 1] = a;

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior  = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        self.child = child;
        self.state = .running;
        std.debug.print("[lumon] [{s}] started (pid={})\n", .{ self.name, child.id });
    }

    pub fn poll(self: *Process) bool {
        if (self.child == null or self.state != .running) return false;
        var child = &self.child.?;
        _ = child.wait() catch return false;
        self.child = null;
        return true;
    }

    pub fn shouldRestart(self: *const Process, exit_code: u8) bool {
        if (self.svc.max_restarts) |max| {
            if (self.restart_count >= max) return false;
        }
        return switch (self.restart) {
            .never => false,
            .always => true,
            .on_failure => exit_code != 0,
        };
    }
};

pub fn runHealthCheck(self: *Process, cmd: []const u8) !bool {
    var argv = [_][]const u8{ "/bin/sh", "-c", cmd };
    var child = std.process.Child.init(&argv, self.allocator);
    child.stdin_behavior  = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const result = try child.wait();
    return switch (result) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// reapZombies: non-blocking wait to prevent zombie accumulation
pub fn reapZombies(allocator: std.mem.Allocator) void {
    _ = allocator;
    // On POSIX systems, waitpid with WNOHANG reaps any exited child
    while (true) {
        const result = std.posix.waitpid(-1, std.posix.W.NOHANG) catch return;
        if (result.pid == 0) break; // no more zombies
    }
}
