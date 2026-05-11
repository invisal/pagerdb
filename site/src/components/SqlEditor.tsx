import { useState, useEffect, useRef } from 'react';
import { ManagedDatabase } from '../pagerdb.js';

type QueryResult =
  | { type: 'select'; columns: string[]; rows: unknown[][] }
  | { type: 'affected'; count: number }
  | { type: 'created' }
  | { type: 'error'; code: string; message: string };

const INITIAL_SQL = `-- Welcome to PagerDB!
CREATE TABLE users (id INT, name TEXT, age INT);
INSERT INTO users VALUES (1, 'Alice', 30);
INSERT INTO users VALUES (2, 'Bob', 25);
INSERT INTO users VALUES (3, 'Carol', 35);
SELECT * FROM users;`;

export default function SqlEditor() {
  const [sql, setSql] = useState(INITIAL_SQL);
  const [result, setResult] = useState<QueryResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const dbRef = useRef<ManagedDatabase | null>(null);

  useEffect(() => {
    ManagedDatabase.open('/pagerdb.wasm')
      .then((db) => { dbRef.current = db; })
      .catch((e) => setError(`Failed to load PagerDB: ${e.message}`));

    return () => { dbRef.current?.close(); };
  }, []);

  function execute() {
    if (!dbRef.current) return;
    setLoading(true);
    setError(null);
    try {
      // Run each statement; use the last result for display
      const statements = sql.split(';').map((s) => s.trim()).filter(Boolean);
      let last: QueryResult | null = null;
      for (const stmt of statements) {
        last = dbRef.current.execute(stmt) as QueryResult;
      }
      setResult(last);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setResult(null);
    } finally {
      setLoading(false);
    }
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      execute();
    }
  }

  return (
    <div className="flex flex-col gap-4 w-full max-w-5xl mx-auto">
      {/* Editor */}
      <div className="relative">
        <textarea
          value={sql}
          onChange={(e) => setSql(e.target.value)}
          onKeyDown={handleKeyDown}
          spellCheck={false}
          rows={10}
          className="w-full font-mono text-sm bg-gray-900 border border-gray-700 rounded-lg p-4 text-gray-100 resize-y focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent placeholder-gray-600"
          placeholder="Type SQL here..."
        />
        <span className="absolute bottom-3 right-3 text-xs text-gray-600 select-none pointer-events-none">
          Ctrl+Enter to run
        </span>
      </div>

      {/* Run button */}
      <div className="flex items-center gap-3">
        <button
          onClick={execute}
          disabled={loading || !sql.trim()}
          className="px-5 py-2 bg-blue-600 hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed rounded-lg text-sm font-medium transition-colors"
        >
          {loading ? 'Running…' : 'Execute'}
        </button>
        {result && result.type !== 'error' && (
          <span className="text-xs text-gray-500">
            {result.type === 'select'
              ? `${result.rows.length} row${result.rows.length !== 1 ? 's' : ''}`
              : result.type === 'affected'
                ? `${result.count} row${result.count !== 1 ? 's' : ''} affected`
                : 'OK'}
          </span>
        )}
      </div>

      {/* Error */}
      {error && (
        <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-3 text-sm text-red-300 font-mono">
          {error}
        </div>
      )}

      {/* Results table */}
      {result && result.type === 'select' && (
        <div className="overflow-auto rounded-lg border border-gray-800">
          <table className="w-full text-sm text-left">
            <thead className="bg-gray-900 text-gray-400 uppercase text-xs tracking-wider">
              <tr>
                {result.columns.map((col) => (
                  <th key={col} className="px-4 py-3 font-medium border-b border-gray-800">
                    {col}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {result.rows.map((row, i) => (
                <tr
                  key={i}
                  className="border-b border-gray-800 last:border-0 hover:bg-gray-900/60 transition-colors"
                >
                  {row.map((cell, j) => (
                    <td key={j} className="px-4 py-3 font-mono text-gray-200">
                      {cell === null ? (
                        <span className="text-gray-600 italic">NULL</span>
                      ) : (
                        String(cell)
                      )}
                    </td>
                  ))}
                </tr>
              ))}
              {result.rows.length === 0 && (
                <tr>
                  <td
                    colSpan={result.columns.length}
                    className="px-4 py-6 text-center text-gray-600"
                  >
                    No rows returned
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      {/* SQL error */}
      {result && result.type === 'error' && (
        <div className="bg-red-950 border border-red-800 rounded-lg px-4 py-3 text-sm text-red-300 font-mono">
          <span className="text-red-500 font-semibold">{result.code}: </span>
          {result.message}
        </div>
      )}

      {/* Non-select success */}
      {result && result.type === 'affected' && (
        <div className="bg-green-950 border border-green-800 rounded-lg px-4 py-3 text-sm text-green-300">
          {result.count} row{result.count !== 1 ? 's' : ''} affected
        </div>
      )}
      {result && result.type === 'created' && (
        <div className="bg-green-950 border border-green-800 rounded-lg px-4 py-3 text-sm text-green-300">
          Table created successfully
        </div>
      )}
    </div>
  );
}
