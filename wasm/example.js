// Run: node wasm/example.js  (after: zig build wasm)
import { ManagedDatabase } from './pagerdb.js';
import { readFileSync } from 'fs';

const db = await ManagedDatabase.open(readFileSync('./../zig-out/bin/pagerdb.wasm'));

db.execute("CREATE TABLE users (id int, name text, score real)");

db.execute("INSERT INTO users VALUES (1, 'Alice', 9.5)");
db.execute("INSERT INTO users VALUES (2, 'Bob',   7.2)");
db.execute("INSERT INTO users VALUES (3, 'Carol', 8.8)");

console.log("All users:");
console.log(db.execute("SELECT * FROM users"));

console.log("\nHigh scorers (score > 8):");
console.log(db.execute("SELECT name, score FROM users WHERE score > 8"));

console.log("\nCount:");
console.log(db.execute("SELECT COUNT(*) FROM users"));

console.log("\nUnknown table (error handling):");
console.log(db.execute("SELECT * FROM orders"));

db.close();
