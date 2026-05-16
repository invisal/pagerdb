const std = @import("std");
const execute = @import("../../sql/executor.zig").execute;
const th = @import("../../test_helpers.zig");
const makeDiskDb = th.makeDiskDb;
const loadDiskDb = th.loadDiskDb;
const exec = th.exec;

test "DEFAULT value survives database reopen" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    {
        const h = try makeDiskDb(alloc, io, "/tmp/test_sql_default_reopen.db", .{});
        defer h.db.close();
        try exec(alloc, h.db, "CREATE TABLE t (name TEXT, age INT DEFAULT 18)");
    }

    const h = try loadDiskDb(alloc, io, "/tmp/test_sql_default_reopen.db");
    defer h.deinit();

    var r1 = try execute(alloc, h.db, "SELECT COLUMN_DEFAULT FROM information_schema.columns WHERE COLUMN_NAME = 'age' AND TABLE_NAME='t';");
    defer r1.deinit();

    try std.testing.expectEqualStrings("18", r1.result_set.rows[0].values[0].text);

    try exec(alloc, h.db, "INSERT INTO t(name) VALUES ('alice')");

    var r2 = try execute(alloc, h.db, "SELECT age FROM t WHERE name = 'alice'");
    defer r2.deinit();
    try std.testing.expectEqual(@as(i64, 18), r2.result_set.rows[0].values[0].int);
}
