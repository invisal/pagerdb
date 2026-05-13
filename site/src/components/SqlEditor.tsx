import { useState, useEffect, useRef, useLayoutEffect, useMemo } from 'react';
import CodeMirror from '@uiw/react-codemirror';
import { sql } from '@codemirror/lang-sql';
import { EditorView, keymap } from '@codemirror/view';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';
import { Prec } from '@codemirror/state';
import { ManagedDatabase } from '../pagerdb.js';

type QueryResult =
  | { type: 'select'; columns: string[]; rows: unknown[][] }
  | { type: 'affected'; count: number }
  | { type: 'created' }
  | { type: 'error'; code: string; message: string };

const SETUP_SQL = `
CREATE TABLE users (
  id         INT NOT NULL,
  name       TEXT    NOT NULL,
  email      TEXT    NOT NULL,
  created_at TEXT    NOT NULL
);
CREATE TABLE products (
  id       INT NOT NULL,
  name     TEXT    NOT NULL,
  category TEXT    NOT NULL,
  price    REAL    NOT NULL
);
CREATE TABLE orders (
  id         INT NOT NULL,
  user_id    INT NOT NULL,
  total      REAL    NOT NULL,
  created_at TEXT    NOT NULL
);
CREATE TABLE order_items (
  id         INT NOT NULL,
  order_id   INT NOT NULL,
  product_id INT NOT NULL,
  quantity   INT NOT NULL,
  unit_price REAL    NOT NULL
);

INSERT INTO users VALUES (1,  'Alice Nguyen',   'alice@example.com',  '2025-11-03');
INSERT INTO users VALUES (2,  'Bob Carter',     'bob@example.com',    '2025-12-14');
INSERT INTO users VALUES (3,  'Clara Diaz',     'clara@example.com',  '2026-01-07');
INSERT INTO users VALUES (4,  'David Kim',      'david@example.com',  '2026-01-19');
INSERT INTO users VALUES (5,  'Eva Petrov',     'eva@example.com',    '2026-02-02');
INSERT INTO users VALUES (6,  'Frank Osei',     'frank@example.com',  '2026-02-11');
INSERT INTO users VALUES (7,  'Grace Liu',      'grace@example.com',  '2026-02-28');
INSERT INTO users VALUES (8,  'Hugo Martins',   'hugo@example.com',   '2026-03-05');
INSERT INTO users VALUES (9,  'Iris Johansson', 'iris@example.com',   '2026-03-18');
INSERT INTO users VALUES (10, 'James Patel',    'james@example.com',  '2026-04-01');

INSERT INTO products VALUES (1,  'Mechanical Keyboard', 'Electronics', 129.00);
INSERT INTO products VALUES (2,  'USB-C Hub',           'Electronics',  49.99);
INSERT INTO products VALUES (3,  'Monitor Stand',       'Accessories',  39.00);
INSERT INTO products VALUES (4,  'Webcam HD',           'Electronics',  79.99);
INSERT INTO products VALUES (5,  'Desk Lamp',           'Accessories',  34.50);
INSERT INTO products VALUES (6,  'Notebook Set',        'Stationery',   12.00);
INSERT INTO products VALUES (7,  'Mouse Pad XL',        'Accessories',  19.99);
INSERT INTO products VALUES (8,  'Headphones',          'Electronics',  89.00);
INSERT INTO products VALUES (9,  'Cable Organiser',     'Accessories',   9.99);
INSERT INTO products VALUES (10, 'Standing Desk Mat',   'Accessories',  45.00);

INSERT INTO orders VALUES (1,  3,  169.99, '2026-01-08');
INSERT INTO orders VALUES (2,  1,  258.00, '2026-01-15');
INSERT INTO orders VALUES (3,  5,   49.99, '2026-02-03');
INSERT INTO orders VALUES (4,  2,  129.00, '2026-02-10');
INSERT INTO orders VALUES (5,  4,  213.49, '2026-02-14');
INSERT INTO orders VALUES (6,  3,   89.00, '2026-02-20');
INSERT INTO orders VALUES (7,  7,  168.99, '2026-03-01');
INSERT INTO orders VALUES (8,  1,   34.50, '2026-03-07');
INSERT INTO orders VALUES (9,  6,  109.98, '2026-03-12');
INSERT INTO orders VALUES (10, 8,   79.99, '2026-03-15');
INSERT INTO orders VALUES (11, 5,  258.00, '2026-03-22');
INSERT INTO orders VALUES (12, 9,   54.99, '2026-03-28');
INSERT INTO orders VALUES (13, 2,  174.50, '2026-04-02');
INSERT INTO orders VALUES (14, 10, 128.99, '2026-04-05');
INSERT INTO orders VALUES (15, 4,   89.00, '2026-04-09');

INSERT INTO order_items VALUES (1,  1,  2,  1,  49.99);
INSERT INTO order_items VALUES (2,  1,  4,  1,  79.99);
INSERT INTO order_items VALUES (3,  1,  9,  4,   9.99);
INSERT INTO order_items VALUES (4,  2,  1,  2, 129.00);
INSERT INTO order_items VALUES (5,  3,  2,  1,  49.99);
INSERT INTO order_items VALUES (6,  4,  1,  1, 129.00);
INSERT INTO order_items VALUES (7,  5,  8,  1,  89.00);
INSERT INTO order_items VALUES (8,  5,  3,  2,  39.00);
INSERT INTO order_items VALUES (9,  5,  7,  2,  19.99);
INSERT INTO order_items VALUES (10, 6,  8,  1,  89.00);
INSERT INTO order_items VALUES (11, 7,  1,  1, 129.00);
INSERT INTO order_items VALUES (12, 7,  7,  2,  19.99);
INSERT INTO order_items VALUES (13, 8,  5,  1,  34.50);
INSERT INTO order_items VALUES (14, 9,  6,  5,  12.00);
INSERT INTO order_items VALUES (15, 9,  7,  1,  19.99);
INSERT INTO order_items VALUES (16, 9,  9,  5,   9.99);
INSERT INTO order_items VALUES (17, 10, 4,  1,  79.99);
INSERT INTO order_items VALUES (18, 11, 1,  2, 129.00);
INSERT INTO order_items VALUES (19, 12, 5,  1,  34.50);
INSERT INTO order_items VALUES (20, 12, 9,  2,   9.99);
INSERT INTO order_items VALUES (21, 13, 3,  1,  39.00);
INSERT INTO order_items VALUES (22, 13, 8,  1,  89.00);
INSERT INTO order_items VALUES (23, 13, 10, 1,  45.00);
INSERT INTO order_items VALUES (24, 14, 2,  1,  49.99);
INSERT INTO order_items VALUES (25, 14, 7,  2,  19.99);
INSERT INTO order_items VALUES (26, 14, 9,  4,   9.99);
INSERT INTO order_items VALUES (27, 15, 8,  1,  89.00);
`;

const INITIAL_SQL = `-- internal page storage
SELECT * FROM __pages;

-- slots inside page 2
SELECT * FROM __page_slots(2);

-- all users
SELECT * FROM users;`;

// ── CodeMirror theme matching the site's design tokens ──────────────────────

const pagerTheme = EditorView.theme({
  '&': {
    backgroundColor: 'var(--color-bg)',
    color: 'var(--color-ink)',
  },
  '&.cm-focused': { outline: 'none !important' },
  '.cm-scroller': {
    fontFamily: 'var(--font-mono)',
    fontSize: '13px',
    lineHeight: '1.55',
    overflow: 'auto',
  },
  '.cm-content': {
    padding: '14px',
    minHeight: '200px',
    caretColor: 'var(--color-ink)',
  },
  '.cm-gutters': {
    backgroundColor: 'var(--color-bg)',
    color: 'var(--color-ink4)',
    border: 'none',
    borderRight: '1px dashed var(--color-rule-soft)',
    minWidth: '40px',
  },
  '.cm-lineNumbers .cm-gutterElement': {
    padding: '0 8px 0 0',
    fontSize: '12px',
    minWidth: '40px',
    textAlign: 'right',
  },
  '.cm-activeLine':       { backgroundColor: 'transparent' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent' },
  '.cm-matchingBracket': {
    backgroundColor: 'var(--color-hi)',
    outline: 'none',
  },
}, { dark: false });

const pagerHighlight = HighlightStyle.define([
  { tag: t.keyword,                                    color: 'var(--color-syn-kw)', fontWeight: '600' },
  { tag: [t.function(t.variableName), t.function(t.name), t.special(t.name)],
                                                       color: 'var(--color-syn-fn)' },
  { tag: [t.string, t.special(t.string)],              color: 'var(--color-syn-str)' },
  { tag: t.number,                                     color: 'var(--color-syn-num)' },
  { tag: t.comment,                                    color: 'var(--color-syn-cm)', fontStyle: 'italic' },
  { tag: [t.operator, t.punctuation],                  color: 'var(--color-ink3)' },
  { tag: [t.variableName, t.name],                     color: 'var(--color-ink)' },
]);

// ────────────────────────────────────────────────────────────────────────────

export default function SqlEditor() {
  const [sqlText, setSqlText]   = useState(INITIAL_SQL);
  const [result, setResult]     = useState<QueryResult | null>(null);
  const [loading, setLoading]   = useState(false);
  const [elapsed, setElapsed]   = useState<number | null>(null);
  const [dbReady, setDbReady]   = useState(false);
  const [dbError, setDbError]   = useState<string | null>(null);
  const dbRef = useRef<ManagedDatabase | null>(null);
  const editorViewRef = useRef<EditorView | null>(null);
  const lastCursorRef = useRef<number>(0);

  // Keep a stable ref to execute so the keymap closure never goes stale
  const executeRef = useRef<() => void>(() => {});

  useEffect(() => {
    console.log('[pagerdb] opening wasm…');
    ManagedDatabase.open('/pagerdb.wasm')
      .then((db) => {
        console.log('[pagerdb] wasm opened, running setup SQL…');
        dbRef.current = db;
        const stmts = SETUP_SQL.split(';').map((s) => s.trim()).filter(Boolean);
        console.log(`[pagerdb] ${stmts.length} statements to execute`);
        for (let i = 0; i < stmts.length; i++) {
          try {
            const result = db.execute(stmts[i]);
            console.log(`[pagerdb] stmt ${i + 1}/${stmts.length} ok`, result);
          } catch (e) {
            console.error(`[pagerdb] stmt ${i + 1}/${stmts.length} FAILED:`, stmts[i], e);
          }
        }
        console.log('[pagerdb] setup complete, db ready');
        setDbReady(true);
      })
      .catch((e) => {
        console.error('[pagerdb] failed to open wasm:', e);
        setDbError(`Failed to load PagerDB WASM: ${e.message}`);
      });
    return () => { dbRef.current?.close(); };
  }, []);

  function currentStatement(): string {
    let pos = lastCursorRef.current;
    // step back over whitespace then over a trailing ';' so the cursor
    // sitting on or just after a semicolon still resolves to that statement
    while (pos > 0 && /[ \t\n\r]/.test(sqlText[pos - 1])) pos--;
    if (pos > 0 && sqlText[pos - 1] === ';') pos--;
    const start = sqlText.lastIndexOf(';', pos - 1) + 1;
    const end   = sqlText.indexOf(';', pos);
    return sqlText.slice(start, end === -1 ? undefined : end + 1).trim().replace(/;$/, '').trim();
  }

  function execute() {
    if (!dbRef.current || loading) return;
    const stmt = currentStatement();
    if (!stmt) return;
    setLoading(true);
    const t0 = performance.now();
    try {
      const res = dbRef.current.execute(stmt) as QueryResult;
      setElapsed(performance.now() - t0);
      setResult(res);
    } catch (e) {
      setElapsed(performance.now() - t0);
      setResult({ type: 'error', code: 'RUNTIME_ERROR', message: e instanceof Error ? e.message : String(e) });
    } finally {
      setLoading(false);
    }
  }

  // Sync the ref after every render so keymap always sees latest execute
  useLayoutEffect(() => { executeRef.current = execute; });

  const extensions = useMemo(() => [
    sql(),
    pagerTheme,
    syntaxHighlighting(pagerHighlight),
    Prec.highest(keymap.of([{
      key: 'Mod-Enter',
      run: () => { executeRef.current(); return true; },
    }])),
  ], []);

  function StatusLabel() {
    if (dbError)  return <span className="text-accent">[error] wasm failed to load</span>;
    if (!dbReady) return <span>loading wasm…</span>;
    if (loading)  return <span>running…</span>;
    if (!result)  return <span>ready · ⌘↵ to run</span>;
    if (result.type === 'select')
      return <span><span className="text-syn-str">[ok]</span>&nbsp; {result.rows.length} row{result.rows.length !== 1 ? 's' : ''}{elapsed !== null ? ` · ${elapsed.toFixed(1)} ms` : ''}</span>;
    if (result.type === 'affected')
      return <span><span className="text-syn-str">[ok]</span>&nbsp; {result.count} row{result.count !== 1 ? 's' : ''} affected{elapsed !== null ? ` · ${elapsed.toFixed(1)} ms` : ''}</span>;
    if (result.type === 'created')
      return <span><span className="text-syn-str">[ok]</span>&nbsp; table created{elapsed !== null ? ` · ${elapsed.toFixed(1)} ms` : ''}</span>;
    if (result.type === 'error')
      return <span><span className="text-accent">[err]</span>&nbsp; {result.code}</span>;
    return null;
  }

  return (
    <div className="border border-rule bg-bg overflow-hidden font-mono text-[13px] leading-[1.55]" role="region" aria-label="SQL editor">

      {/* Bar */}
      <div className="flex items-center justify-between px-3 py-2 border-b border-rule text-[11px] uppercase tracking-[0.08em] text-ink3 bg-bg2">
        <div className="flex items-center gap-2">
          <span className="text-accent">●</span>
          <b className="text-ink font-semibold">query.sql</b>
        </div>
        <button
          className="run-btn border border-rule bg-ink text-bg px-[10px] py-1 font-mono text-[11px] uppercase tracking-[0.08em] cursor-pointer inline-flex gap-[6px] items-center hover:bg-accent hover:border-accent hover:text-white disabled:opacity-50 disabled:cursor-not-allowed"
          type="button"
          onClick={execute}
          disabled={loading || !dbReady}
        >
          run · ⌘↵
        </button>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-rule text-[11px] uppercase tracking-[0.08em] bg-bg" role="tablist">
        <button role="tab" aria-selected="true"
          className="tab-active bg-bg2 text-ink border-0 border-r border-dashed border-rule-soft px-[14px] py-2 font-mono text-[11px] uppercase tracking-[0.08em] cursor-pointer">
          query.sql
        </button>
        <button role="tab" aria-selected="false"
          className="text-ink3 border-0 border-r border-dashed border-rule-soft px-[14px] py-2 bg-transparent font-mono text-[11px] uppercase tracking-[0.08em] cursor-pointer">
          schema.sql
        </button>
      </div>

      {/* Editor */}
      <CodeMirror
        value={sqlText}
        onChange={(val) => setSqlText(val)}
        extensions={extensions}
        basicSetup={{
          lineNumbers:                true,
          highlightActiveLine:        false,
          highlightActiveLineGutter:  false,
          foldGutter:                 false,
          drawSelection:              false,
          highlightSelectionMatches:  false,
          autocompletion:             false,
          searchKeymap:               false,
          syntaxHighlighting:         false,
        }}
        theme="none"
        aria-label="SQL source"
        onCreateEditor={(view) => { editorViewRef.current = view; }}
        onUpdate={(update) => { lastCursorRef.current = update.state.selection.main.head; }}
      />

      {/* Results */}
      <div className="border-t border-rule bg-bg2">
        <div className="flex justify-between px-3 py-2 text-[11px] uppercase tracking-[0.08em] text-ink3 border-b border-dashed border-rule-soft flex-wrap gap-2">
          <span><StatusLabel /></span>
        </div>

        {result?.type === 'select' && (
          <div className="overflow-x-auto">
            <table className="w-full border-collapse font-mono text-[12.5px] bg-bg">
              <thead>
                <tr>
                  {result.columns.map((col) => (
                    <th key={col} className="text-left font-semibold px-3 py-[7px] text-ink3 uppercase text-[10.5px] tracking-[0.10em] border-b border-rule bg-bg2">
                      {col}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {result.rows.length === 0 && (
                  <tr><td colSpan={result.columns.length} className="px-3 py-3 text-ink3">no rows returned</td></tr>
                )}
                {result.rows.map((row, i) => (
                  <tr key={i} className="border-b border-dashed border-rule-soft last:border-0">
                    {row.map((cell, j) => (
                      <td key={j} className={`px-3 py-[6px] text-ink ${typeof cell === 'number' ? 'text-right text-syn-num' : ''}`}>
                        {cell === null ? <span className="text-ink3">NULL</span> : String(cell)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {result?.type === 'error' && (
          <p className="m-0 px-[14px] py-[10px] text-[12.5px] font-mono text-accent">
            {result.code}: {result.message}
          </p>
        )}
      </div>
    </div>
  );
}
