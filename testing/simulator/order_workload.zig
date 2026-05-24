const std = @import("std");
const core = @import("core");
const runner = @import("runner.zig");
const Database = core.ManagedDatabase;

fn rollback(db: *Database, alloc: std.mem.Allocator) void {
    var r = db.execute("ROLLBACK", alloc) catch return;
    r.deinit();
}

pub const OrderWorkload = struct {
    alloc: std.mem.Allocator,

    // Sequential ID counters — each table's IDs are 1-based and contiguous,
    // so "pick a random existing row" is just random(1..count).
    user_count: u64 = 0,
    product_count: u64 = 0,
    order_count: u64 = 0,
    detail_next_id: u64 = 1,

    const vtable = runner.Workload.VTable{
        .name = "ORDER",
        .setup = vtableSetup,
        .next = vtableNext,
        .verify = vtableVerify,
    };

    fn vtableSetup(ptr: *anyopaque, db: *Database, rng: std.Random) anyerror!void {
        const self: *OrderWorkload = @ptrCast(@alignCast(ptr));
        return self.setup(db, rng);
    }

    fn vtableNext(ptr: *anyopaque, db: *Database, rng: std.Random) anyerror!void {
        const self: *OrderWorkload = @ptrCast(@alignCast(ptr));
        return self.next(db, rng);
    }

    fn vtableVerify(_: *anyopaque, _: *Database, _: std.Random) anyerror!void {}

    pub fn init(alloc: std.mem.Allocator) OrderWorkload {
        return .{ .alloc = alloc };
    }

    pub fn workload(self: *OrderWorkload) runner.Workload {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn setup(self: *OrderWorkload, db: *Database, _: std.Random) !void {
        _ = try db.execute("CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT)", self.alloc);
        _ = try db.execute("CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT, price INT, qty INT)", self.alloc);
        _ = try db.execute("CREATE TABLE orders(id INTEGER PRIMARY KEY, user_id INT, status TEXT, created_at INT)", self.alloc);
        _ = try db.execute("CREATE TABLE orders_detail(id INTEGER PRIMARY KEY, order_id INT, product_id INT, unit_price INT, qty INT, total INT)", self.alloc);
    }

    // Pick the next action using weighted random selection.
    // Ensures we have at least one user and one product before placing orders.
    pub fn next(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        if (self.user_count == 0) return self.addUser(db, rng);
        if (self.product_count == 0) return self.addProduct(db, rng);

        // Weights: makeOrder 40%, cancelOrder 15%, restock 15%, addProduct 10%, addUser 10%, query 10%
        const roll = rng.uintLessThan(u8, 100);
        if (roll < 40) return self.makeOrder(db, rng);
        if (roll < 55) return self.cancelOrder(db, rng);
        if (roll < 70) return self.restockProduct(db, rng);
        if (roll < 80) return self.addProduct(db, rng);
        if (roll < 90) return self.addUser(db, rng);
        return self.queryOrderHistory(db, rng);
    }

    fn addUser(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        self.user_count += 1;
        const id = self.user_count;

        var sql_buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO users VALUES ({d}, 'user_{d}')", .{ id, rng.int(u32) });
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
    }

    fn addProduct(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        self.product_count += 1;
        const id = self.product_count;
        // Price between 1 and 999, initial stock between 10 and 109.
        const price = rng.uintLessThan(u32, 999) + 1;
        const qty = rng.uintLessThan(u32, 100) + 10;

        var sql_buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO products VALUES ({d}, 'product_{d}', {d}, {d})", .{ id, id, price, qty });
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
    }

    fn restockProduct(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        const product_id = rng.uintLessThan(u64, self.product_count) + 1;
        const restock_qty = rng.uintLessThan(u32, 50) + 10;

        var sql_buf: [128]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "UPDATE products SET qty = qty + {d} WHERE id = {d}", .{ restock_qty, product_id });
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
    }

    fn makeOrder(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        // Pick a random product and read its current price and qty.
        const product_id = rng.uintLessThan(u64, self.product_count) + 1;
        var price_buf: [96]u8 = undefined;
        const price_sql = try std.fmt.bufPrint(&price_buf, "SELECT price, qty FROM products WHERE id = {d}", .{product_id});
        var price_result = try db.execute(price_sql, self.alloc);
        defer price_result.deinit();

        const rs = price_result.result_set;
        if (rs.rows.len == 0) return;
        const price = rs.rows[0].values[0].int;
        const available_qty: i64 = rs.rows[0].values[1].int;
        if (available_qty <= 0) return;

        const order_qty: i64 = @intCast(rng.uintLessThan(u32, @intCast(@min(available_qty, 5))) + 1);
        const total = price * order_qty;
        const user_id = rng.uintLessThan(u64, self.user_count) + 1;

        self.order_count += 1;
        const order_id = self.order_count;
        const detail_id = self.detail_next_id;
        self.detail_next_id += 1;

        var begin_result = try db.execute("BEGIN", self.alloc);
        defer begin_result.deinit();
        errdefer rollback(db, self.alloc);

        var sql_buf: [128]u8 = undefined;
        const order_sql = try std.fmt.bufPrint(&sql_buf, "INSERT INTO orders VALUES ({d}, {d}, 'active', 0)", .{ order_id, user_id });
        var order_result = try db.execute(order_sql, self.alloc);
        defer order_result.deinit();

        var detail_buf: [160]u8 = undefined;
        const detail_sql = try std.fmt.bufPrint(&detail_buf, "INSERT INTO orders_detail VALUES ({d}, {d}, {d}, {d}, {d}, {d})", .{ detail_id, order_id, product_id, price, order_qty, total });
        var detail_result = try db.execute(detail_sql, self.alloc);
        defer detail_result.deinit();

        var update_buf: [96]u8 = undefined;
        const update_sql = try std.fmt.bufPrint(&update_buf, "UPDATE products SET qty = qty - {d} WHERE id = {d}", .{ order_qty, product_id });
        var update_result = try db.execute(update_sql, self.alloc);
        defer update_result.deinit();

        var commit_result = try db.execute("COMMIT", self.alloc);
        defer commit_result.deinit();
    }

    fn cancelOrder(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        if (self.order_count == 0) return;

        const order_id = rng.uintLessThan(u64, self.order_count) + 1;
        var status_buf: [96]u8 = undefined;
        const status_sql = try std.fmt.bufPrint(&status_buf, "SELECT status FROM orders WHERE id = {d}", .{order_id});
        var status_result = try db.execute(status_sql, self.alloc);
        defer status_result.deinit();

        if (status_result.result_set.rows.len == 0) return;
        const status = status_result.result_set.rows[0].values[0].text;
        if (!std.mem.eql(u8, status, "active")) return;

        // Restore stock for every line item in this order.
        var detail_buf: [128]u8 = undefined;
        const detail_sql = try std.fmt.bufPrint(&detail_buf, "SELECT product_id, qty FROM orders_detail WHERE order_id = {d}", .{order_id});
        var detail_result = try db.execute(detail_sql, self.alloc);
        defer detail_result.deinit();

        for (detail_result.result_set.rows) |row| {
            const product_id = row.values[0].int;
            const qty = row.values[1].int;

            var restore_buf: [96]u8 = undefined;
            const restore_sql = try std.fmt.bufPrint(&restore_buf, "UPDATE products SET qty = qty + {d} WHERE id = {d}", .{ qty, product_id });
            var restore_result = try db.execute(restore_sql, self.alloc);
            defer restore_result.deinit();
        }

        var cancel_buf: [96]u8 = undefined;
        const cancel_sql = try std.fmt.bufPrint(&cancel_buf, "UPDATE orders SET status = 'cancelled' WHERE id = {d}", .{order_id});
        var cancel_result = try db.execute(cancel_sql, self.alloc);
        defer cancel_result.deinit();
    }

    fn queryOrderHistory(self: *OrderWorkload, db: *Database, rng: std.Random) !void {
        if (self.user_count == 0) return;

        const user_id = rng.uintLessThan(u64, self.user_count) + 1;
        var sql_buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buf, "SELECT o.id, od.product_id, od.total FROM orders o JOIN orders_detail od ON o.id = od.order_id WHERE o.user_id = {d}", .{user_id});
        var result = try db.execute(sql, self.alloc);
        defer result.deinit();
    }
};

test "order workload: 10_000 operations complete without error" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    var io = core.SimIo.init(alloc);
    defer io.deinit();

    var db = try Database.open(alloc, io.io(), "/order_workload_test.db");
    defer db.deinit();

    var w = OrderWorkload.init(alloc);
    try w.setup(&db, rng);
    for (0..10_000) |_| try w.next(&db, rng);
}
