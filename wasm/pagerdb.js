/**
 * PagerDB WASM binding — JavaScript wrapper.
 *
 * Mirrors the Zig ManagedDatabase API: open, execute, close.
 * The WASM module runs a full in-memory SQL database; no files are touched.
 *
 * @example Browser
 *   import { ManagedDatabase } from './pagerdb.js';
 *   const db = await ManagedDatabase.open('/path/to/pagerdb.wasm');
 *   db.execute("CREATE TABLE users (id int, name text)");
 *   db.execute("INSERT INTO users VALUES (1, 'Alice')");
 *   const result = db.execute("SELECT * FROM users");
 *   // { type: "select", columns: ["id","name"], rows: [[1,"Alice"]] }
 *   db.close();
 *
 * @example Node.js
 *   import { ManagedDatabase } from './pagerdb.js';
 *   import { readFileSync } from 'fs';
 *   const db = await ManagedDatabase.open(readFileSync('./pagerdb.wasm'));
 */

export class ManagedDatabase {
    #exports;
    #encoder = new TextEncoder();
    #decoder = new TextDecoder();

    /** @param {WebAssembly.Exports} exports */
    constructor(exports) {
        this.#exports = exports;
    }

    /**
     * Open an in-memory database from a WASM module.
     * @param {string | URL | BufferSource} wasmUrlOrBuffer
     *   A URL/path (browser) or a Buffer/Uint8Array (Node.js).
     * @returns {Promise<ManagedDatabase>}
     */
    static async open(wasmUrlOrBuffer) {
        let instance;
        if (typeof wasmUrlOrBuffer === 'string' || wasmUrlOrBuffer instanceof URL) {
            ({ instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrlOrBuffer), {}));
        } else {
            ({ instance } = await WebAssembly.instantiate(wasmUrlOrBuffer, {}));
        }

        if (instance.exports.db_init() !== 0) {
            throw new Error("PagerDB: failed to initialise in-memory database");
        }

        return new ManagedDatabase(instance.exports);
    }

    /**
     * Execute a SQL statement and return the result.
     *
     * Result shapes:
     *   SELECT  → { type: "select",   columns: string[], rows: any[][] }
     *   DML     → { type: "affected", count: number }
     *   DDL     → { type: "created" }
     *   Error   → { type: "error",    message: string }
     *
     * @param {string} sql
     * @returns {{ type: string, columns?: string[], rows?: any[][], count?: number, message?: string }}
     */
    execute(sql) {
        const { memory, db_alloc, db_free, db_exec, db_result_ptr } = this.#exports;

        const bytes = this.#encoder.encode(sql);
        const ptr = db_alloc(bytes.length);
        if (ptr === 0) throw new Error("PagerDB: out of WASM memory");

        new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
        const len = db_exec(ptr, bytes.length);
        db_free(ptr, bytes.length);

        if (len < 0) throw new Error("PagerDB: internal WASM error");

        // Read before any subsequent WASM call; memory.buffer is invalidated by wasmMemoryGrow.
        const resultBytes = new Uint8Array(memory.buffer, db_result_ptr(), len);
        return JSON.parse(this.#decoder.decode(resultBytes));
    }

    /** Close the database and release all WASM resources. */
    close() {
        this.#exports.db_close();
    }
}
