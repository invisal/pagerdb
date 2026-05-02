// Minimal example of using PagerDB.
// Demonstrates basic database operations: creating a table, inserting data,
// and querying results using an in-memory pager.

const std = @import("std");

const PagerDB = @import("core");
const Database = PagerDB.Database;
const InMemoryPager = PagerDB.InMemoryPager;
const exec = PagerDB.execute;

pub fn main(init: std.process.Init) !void {
    const pager = try InMemoryPager.create(init.gpa);

    const db = try Database.init(pager, init.gpa);
    defer db.close();

    var r1 = try exec(db, "CREATE TABLE users(id INT, name TEXT);", init.gpa);
    defer r1.deinit();

    var r2 = try exec(db, "INSERT INTO users VALUES(1, 'Visal');", init.gpa);
    defer r2.deinit();

    var result = try exec(db, "SELECT * FROM users;", init.gpa);
    defer result.deinit();

    PagerDB.debug.print(result);
}
