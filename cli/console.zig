const std = @import("std");

// Console provides raw terminal input for the REPL.
// We bypass std.io.BufferedReader and use raw mode to handle:
//   - Arrow keys for cursor movement
//   - History navigation (up/down)
//   - Line editing (backspace, delete) without echoing control characters
pub fn Console(comptime Io: type) type {
    return struct {
        const Self = @This();

        pub const Result = union(enum) {
            line: []u8, // slice into the caller's buf; empty on Ctrl+C
            history_up,
            history_down,
        };

        stdin: std.Io.File,
        io: Io,
        origin: std.posix.termios,
        out_buf: [4096]u8,
        in_buf: [256]u8,

        pub fn setup(io: Io) !Self {
            const stdin = std.Io.File.stdin();
            const origin = try std.posix.tcgetattr(stdin.handle);

            var raw = origin;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            try std.posix.tcsetattr(stdin.handle, .NOW, raw);

            return .{
                .stdin = stdin,
                .io = io,
                .origin = origin,
                .out_buf = undefined,
                .in_buf = undefined,
            };
        }

        pub fn restore(self: *Self) void {
            std.posix.tcsetattr(self.stdin.handle, .NOW, self.origin) catch {};
        }

        // Reads one line. `prefill` is written into buf as the starting content
        // (used by the caller to replay a history entry into the editing buffer).
        // Returns null on EOF (Ctrl+D on empty input).
        // Returns .history_up/.history_down without printing a newline so the
        // caller can immediately call readLine again with the new prefill and
        // the display overwrites cleanly.
        pub fn readLine(self: *Self, prompt: []const u8, buf: []u8, prefill: []const u8) !?Result {
            var out = std.Io.File.stdout().writerStreaming(self.io, &self.out_buf);
            var in = self.stdin.reader(self.io, &self.in_buf);

            const init_len = @min(prefill.len, buf.len);
            @memcpy(buf[0..init_len], prefill[0..init_len]);
            var len: usize = init_len;
            var cursor: usize = init_len;

            // Initial render (also serves as overwrite when called after history nav)
            try render(&out, prompt, buf[0..len], cursor);

            while (true) {
                const b = in.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => return null,
                    else => return err,
                };

                switch (b) {
                    0x04 => if (len == 0) return null, // Ctrl+D on empty = EOF

                    0x03 => { // Ctrl+C — discard line
                        try out.interface.writeAll("\n");
                        try out.interface.flush();
                        return .{ .line = buf[0..0] };
                    },

                    0x1b => {
                        const b1 = in.interface.takeByte() catch continue;
                        const b2 = in.interface.takeByte() catch continue;
                        if (b1 != '[') continue;
                        switch (b2) {
                            'A' => return .history_up,
                            'B' => return .history_down,
                            'D' => if (cursor > 0) {
                                cursor -= 1;
                            },
                            'C' => if (cursor < len) {
                                cursor += 1;
                            },
                            '3' => { // Delete key (ESC [ 3 ~)
                                const b3 = in.interface.takeByte() catch continue;
                                if (b3 == '~' and cursor < len) {
                                    const tail = len - cursor - 1;
                                    std.mem.copyForwards(u8, buf[cursor .. cursor + tail], buf[cursor + 1 .. cursor + 1 + tail]);
                                    len -= 1;
                                }
                            },
                            else => {},
                        }
                    },

                    '\n', '\r' => {
                        try out.interface.writeAll("\n");
                        try out.interface.flush();
                        return .{ .line = buf[0..len] };
                    },

                    '\x7f' => { // Backspace
                        if (cursor > 0) {
                            cursor -= 1;
                            const tail = len - cursor - 1;
                            std.mem.copyForwards(u8, buf[cursor .. cursor + tail], buf[cursor + 1 .. cursor + 1 + tail]);
                            len -= 1;
                        }
                    },

                    else => {
                        if (len < buf.len) {
                            if (cursor < len)
                                std.mem.copyBackwards(u8, buf[cursor + 1 .. len + 1], buf[cursor..len]);
                            buf[cursor] = b;
                            len += 1;
                            cursor += 1;
                        }
                    },
                }

                try render(&out, prompt, buf[0..len], cursor);
            }
        }

        fn render(out: anytype, prompt: []const u8, content: []const u8, cursor: usize) !void {
            try out.interface.writeAll("\r");
            try out.interface.writeAll(prompt);
            try out.interface.writeAll(content);
            try out.interface.writeAll("\x1b[K");
            const move_left = content.len - cursor;
            if (move_left > 0) try out.interface.print("\x1b[{}D", .{move_left});
            try out.interface.flush();
        }
    };
}
