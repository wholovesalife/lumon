const std = @import("std");
const config = @import("config.zig");
const log_mod = @import("log.zig");

pub const ProcessState = enum {
    stopped,
    starting,
    running,
    stopping,
    crashed,
    failed, // exceeded max_restarts
};

pub const Process = struct {
    allocator:    std.mem.Allocator,
    svc:          config.ServiceConfig,
    state:        ProcessState,
    pid:          ?std.process.Child.Id,
    child:        ?std.process.Child,
    restart_count: u32,
    last_start:   i64,
    logger:       *log_mod.Logger,

    pub fn init(allocator: std.mem.Allocator, svc: config.ServiceConfig, logger: *log_mod.Logger) Process {
        return .{
            .allocator     = allocator,
            .svc           = svc,
            .state         = .stopped,
            .pid           = null,
            .child         = null,
            .restart_count = 0,
            .last_start    = 0,
            .logger        = logger,
        };
    }

    pub fn start(self: *Process) !void {
        self.state = .starting;
        self.last_start = std.time.timestamp();

        const argv_len = 1 + self.svc.args.len;
        var argv = try self.allocator.alloc([]const u8, argv_len);
        defer self.allocator.free(argv);
        argv[0] = self.svc.cmd;
        for (self.svc.args, 0..) |a, i| argv[i + 1] = a;

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior  = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        if (self.svc.cwd) |cwd| child.cwd = cwd;

        if (self.svc.env.count() > 0) {
            var env_map = try std.process.getEnvMap(self.allocator);
            defer env_map.deinit();
            var it = self.svc.env.iterator();
            while (it.next()) |entry| {
                try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
            }
            child.env_map = &env_map;
        }

        try child.spawn();
        self.child = child;
        self.pid   = child.id;
        self.state = .running;

        self.logger.info(self.svc.name, "started (pid={})", .{child.id});
    }

    pub fn stop(self: *Process) void {
        if (self.child) |*child| {
            self.state = .stopping;

            // Run pre-stop hook if configured
            if (self.svc.pre_stop) |cmd| {
                self.logger.info(self.svc.name, "running pre-stop hook: {s}", .{cmd});
                var hook_argv = [_][]const u8{ "/bin/sh", "-c", cmd };
                var hook = std.process.Child.init(&hook_argv, self.allocator);
                hook.spawn() catch {};
                _ = hook.wait() catch {};
            }

            std.posix.kill(child.id, std.posix.SIG.TERM) catch {};

            const deadline = std.time.milliTimestamp() + 5000;
            while (std.time.milliTimestamp() < deadline) {
                const result = child.wait() catch null;
                if (result != null) {
                    self.logger.info(self.svc.name, "stopped gracefully", .{});
                    self.state = .stopped;
                    self.child = null;
                    self.pid   = null;
                    return;
                }
                std.time.sleep(100 * std.time.ns_per_ms);
            }

            self.logger.warn(self.svc.name, "graceful shutdown timed out, sending SIGKILL", .{});
            std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            self.state = .stopped;
            self.child = null;
            self.pid   = null;
        }
    }

    pub fn poll(self: *Process) bool {
        if (self.child == null) return true;
        if (self.state != .running) return false;

        var child = &self.child.?;
        const result = child.wait() catch return false;
        _ = result;

        self.pid   = null;
        self.child = null;
        return true;
    }

    pub fn shouldRestart(self: *Process, exit_code: u8) bool {
        return switch (self.svc.restart) {
            .never => false,
            .always => self.withinRestartBudget(),
            .on_failure => exit_code != 0 and self.withinRestartBudget(),
        };
    }

    fn withinRestartBudget(self: *Process) bool {
        const max = self.svc.max_restarts orelse return true;
        return self.restart_count < max;
    }

    pub fn runHealthCheck(self: *Process) !bool {
        const hc = self.svc.health orelse return true;

        var argv = [_][]const u8{ "/bin/sh", "-c", hc.cmd };
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
        while (true) {
            const result = std.posix.waitpid(-1, std.posix.W.NOHANG) catch return;
            if (result.pid == 0) break;
        }
    }
};
