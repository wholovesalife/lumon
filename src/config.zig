/// config.zig — parse a Lua config file for lumon
/// Reads a Lua table via the Lua C API (or a pure-Zig subset).
///
/// Because embedding full Lua requires liblua, we use a simple hand-rolled
/// Lua-subset reader that handles the services.lua format:
///   return { { name="..", cmd="..", args={..}, restart="..", ... }, ... }
///
/// It is not a general Lua interpreter — it covers exactly the DSL used by
/// lumon configs (table literals, string/number/boolean literals, nested tables).

const std = @import("std");

pub const HealthCheck = struct {
    cmd:      []const u8,
    interval: u32, // seconds
};

pub const RestartPolicy = enum {
    always,
    on_failure,
    never,

    pub fn parse(s: []const u8) !RestartPolicy {
        if (std.mem.eql(u8, s, "always"))     return .always;
        if (std.mem.eql(u8, s, "on-failure")) return .on_failure;
        if (std.mem.eql(u8, s, "on_failure")) return .on_failure;
        if (std.mem.eql(u8, s, "never"))      return .never;
        return error.InvalidRestartPolicy;
    }
};

pub const ServiceConfig = struct {
    name:         []const u8,
    cmd:          []const u8,
    args:         [][]const u8,
    restart:      RestartPolicy,
    max_restarts: ?u32,
    health:       ?HealthCheck,
    env:          std.StringHashMap([]const u8),
    pre_stop:     ?[]const u8,
    cwd:          ?[]const u8,

    pub fn deinit(self: *ServiceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.cmd);
        for (self.args) |a| allocator.free(a);
        allocator.free(self.args);
        if (self.health) |h| allocator.free(h.cmd);
        var it = self.env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.env.deinit();
        if (self.pre_stop) |p| allocator.free(p);
        if (self.cwd) |c| allocator.free(c);
    }
};

// ─── Tokenizer ───────────────────────────────────────────────────────────────

const TokKind = enum {
    word, string, number, equals, comma, lbrace, rbrace, lbracket, rbracket, eof,
};

const Tok = struct { kind: TokKind, val: []const u8 };

const Tokenizer = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn skip(self: *Tokenizer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                // Lua comment
                self.pos += 2;
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else break;
        }
    }

    fn next(self: *Tokenizer) !Tok {
        self.skip();
        if (self.pos >= self.src.len) return Tok{ .kind = .eof, .val = "" };
        const c = self.src[self.pos];
        switch (c) {
            '=' => { self.pos += 1; return Tok{ .kind = .equals, .val = "=" }; },
            ',' => { self.pos += 1; return Tok{ .kind = .comma, .val = "," }; },
            '{' => { self.pos += 1; return Tok{ .kind = .lbrace, .val = "{" }; },
            '}' => { self.pos += 1; return Tok{ .kind = .rbrace, .val = "}" }; },
            '[' => { self.pos += 1; return Tok{ .kind = .lbracket, .val = "[" }; },
            ']' => { self.pos += 1; return Tok{ .kind = .rbracket, .val = "]" }; },
            '"', '\'' => {
                const q = c;
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != q) {
                    if (self.src[self.pos] == '\\') self.pos += 1;
                    self.pos += 1;
                }
                const val = self.src[start..self.pos];
                self.pos += 1;
                return Tok{ .kind = .string, .val = val };
            },
            '-', '0'...'9' => {
                const start = self.pos;
                if (c == '-') self.pos += 1;
                while (self.pos < self.src.len and (
                    (self.src[self.pos] >= '0' and self.src[self.pos] <= '9') or
                    self.src[self.pos] == '.' or self.src[self.pos] == 'e'
                )) self.pos += 1;
                return Tok{ .kind = .number, .val = self.src[start..self.pos] };
            },
            'a'...'z', 'A'...'Z', '_' => {
                const start = self.pos;
                while (self.pos < self.src.len and (
                    (self.src[self.pos] >= 'a' and self.src[self.pos] <= 'z') or
                    (self.src[self.pos] >= 'A' and self.src[self.pos] <= 'Z') or
                    (self.src[self.pos] >= '0' and self.src[self.pos] <= '9') or
                    self.src[self.pos] == '_' or self.src[self.pos] == '-' or self.src[self.pos] == '.'
                )) self.pos += 1;
                return Tok{ .kind = .word, .val = self.src[start..self.pos] };
            },
            else => {
                self.pos += 1;
                return Tok{ .kind = .word, .val = self.src[self.pos-1..self.pos] };
            },
        }
    }

    fn peek(self: *Tokenizer) !Tok {
        const saved = self.pos;
        const t = try self.next();
        self.pos = saved;
        return t;
    }
};

// ─── Parser ──────────────────────────────────────────────────────────────────

pub const ConfigParser = struct {
    tok: Tokenizer,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) ConfigParser {
        return .{ .tok = Tokenizer.init(src), .allocator = allocator };
    }

    pub fn parse(self: *ConfigParser) ![]ServiceConfig {
        // Skip optional "return" keyword
        const first = try self.tok.peek();
        if (first.kind == .word and std.mem.eql(u8, first.val, "return")) {
            _ = try self.tok.next();
        }
        return self.parseServiceArray();
    }

    fn parseServiceArray(self: *ConfigParser) ![]ServiceConfig {
        _ = try self.expectKind(.lbrace);
        var services = std.ArrayList(ServiceConfig).init(self.allocator);
        errdefer {
            for (services.items) |*s| s.deinit(self.allocator);
            services.deinit();
        }

        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .rbrace) { _ = try self.tok.next(); break; }
            if (t.kind == .comma) { _ = try self.tok.next(); continue; }
            if (t.kind == .eof) break;
            const svc = try self.parseService();
            try services.append(svc);
        }

        return try services.toOwnedSlice();
    }

    fn parseService(self: *ConfigParser) !ServiceConfig {
        _ = try self.expectKind(.lbrace);

        var svc = ServiceConfig{
            .name         = "",
            .cmd          = "",
            .args         = &[_][]const u8{},
            .restart      = .on_failure,
            .max_restarts = null,
            .health       = null,
            .env          = std.StringHashMap([]const u8).init(self.allocator),
            .pre_stop     = null,
            .cwd          = null,
        };

        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .rbrace) { _ = try self.tok.next(); break; }
            if (t.kind == .comma) { _ = try self.tok.next(); continue; }
            if (t.kind == .eof) return error.UnexpectedEof;

            const key_tok = try self.tok.next();
            const key = key_tok.val;

            _ = try self.expectKind(.equals);

            if (std.mem.eql(u8, key, "name")) {
                const v = try self.expectString();
                svc.name = try self.allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, key, "cmd")) {
                const v = try self.expectString();
                svc.cmd = try self.allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, key, "restart")) {
                const v = try self.expectString();
                svc.restart = try RestartPolicy.parse(v);
            } else if (std.mem.eql(u8, key, "max_restarts")) {
                const v = try self.expectNumber();
                svc.max_restarts = @intFromFloat(v);
            } else if (std.mem.eql(u8, key, "cwd")) {
                const v = try self.expectString();
                svc.cwd = try self.allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, key, "pre_stop")) {
                const v = try self.expectString();
                svc.pre_stop = try self.allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, key, "args")) {
                svc.args = try self.parseStringArray();
            } else if (std.mem.eql(u8, key, "health")) {
                svc.health = try self.parseHealth();
            } else if (std.mem.eql(u8, key, "env")) {
                try self.parseEnv(&svc.env);
            } else {
                // Skip unknown field
                try self.skipValue();
            }
        }

        return svc;
    }

    fn parseHealth(self: *ConfigParser) !HealthCheck {
        _ = try self.expectKind(.lbrace);
        var h = HealthCheck{ .cmd = "", .interval = 30 };
        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .rbrace) { _ = try self.tok.next(); break; }
            if (t.kind == .comma) { _ = try self.tok.next(); continue; }
            if (t.kind == .eof) return error.UnexpectedEof;

            const key_tok = try self.tok.next();
            _ = try self.expectKind(.equals);
            if (std.mem.eql(u8, key_tok.val, "cmd")) {
                const v = try self.expectString();
                h.cmd = try self.allocator.dupe(u8, v);
            } else if (std.mem.eql(u8, key_tok.val, "interval")) {
                const n = try self.expectNumber();
                h.interval = @intFromFloat(n);
            } else {
                try self.skipValue();
            }
        }
        return h;
    }

    fn parseEnv(self: *ConfigParser, env: *std.StringHashMap([]const u8)) !void {
        _ = try self.expectKind(.lbrace);
        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .rbrace) { _ = try self.tok.next(); break; }
            if (t.kind == .comma) { _ = try self.tok.next(); continue; }
            if (t.kind == .eof) return error.UnexpectedEof;

            const key_tok = try self.tok.next();
            _ = try self.expectKind(.equals);
            const val_str = try self.expectString();
            const k = try self.allocator.dupe(u8, key_tok.val);
            const v = try self.allocator.dupe(u8, val_str);
            try env.put(k, v);
        }
    }

    fn parseStringArray(self: *ConfigParser) ![][]const u8 {
        _ = try self.expectKind(.lbrace);
        var arr = std.ArrayList([]const u8).init(self.allocator);
        while (true) {
            const t = try self.tok.peek();
            if (t.kind == .rbrace) { _ = try self.tok.next(); break; }
            if (t.kind == .comma) { _ = try self.tok.next(); continue; }
            if (t.kind == .eof) return error.UnexpectedEof;
            const s = try self.expectString();
            try arr.append(try self.allocator.dupe(u8, s));
        }
        return try arr.toOwnedSlice();
    }

    fn expectString(self: *ConfigParser) ![]const u8 {
        const t = try self.tok.next();
        if (t.kind == .string or t.kind == .word) return t.val;
        // Handle env var interpolation: check if word starts with process.env
        return error.ExpectedString;
    }

    fn expectNumber(self: *ConfigParser) !f64 {
        const t = try self.tok.next();
        if (t.kind != .number) return error.ExpectedNumber;
        return std.fmt.parseFloat(f64, t.val);
    }

    fn expectKind(self: *ConfigParser, kind: TokKind) !Tok {
        const t = try self.tok.next();
        if (t.kind != kind) return error.UnexpectedToken;
        return t;
    }

    fn skipValue(self: *ConfigParser) !void {
        const t = try self.tok.next();
        if (t.kind == .lbrace) {
            var depth: usize = 1;
            while (depth > 0) {
                const inner = try self.tok.next();
                if (inner.kind == .lbrace) depth += 1;
                if (inner.kind == .rbrace) depth -= 1;
                if (inner.kind == .eof) return error.UnexpectedEof;
            }
        }
        // Otherwise it was a simple value, already consumed
    }
};
