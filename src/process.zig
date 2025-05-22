const std = @import("std");

pub const ProcessState = enum { stopped, running, crashed };

pub const Process = struct {
    name:  []const u8,
    cmd:   []const u8,
    args:  [][]const u8,
    state: ProcessState,
    child: ?std.process.Child,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, cmd: []const u8, args: [][]const u8) Process {
        return .{ .allocator = allocator, .name = name, .cmd = cmd, .args = args, .state = .stopped, .child = null };
    }

    pub fn start(self: *Process) !void {
        const argv_len = 1 + self.args.len;
        var argv = try self.allocator.alloc([]const u8, argv_len);
        defer self.allocator.free(argv);
        argv[0] = self.cmd;
        for (self.args, 0..) |a, i| argv[i + 1] = a;

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        self.child = child;
        self.state = .running;
        std.debug.print("[lumon] started {s} (pid={})\n", .{ self.name, child.id });
    }

    pub fn wait(self: *Process) !void {
        if (self.child) |*child| {
            const result = try child.wait();
            _ = result;
            self.state = .crashed;
            self.child = null;
        }
    }
};
