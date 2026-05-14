import { useState, useMemo } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  type ColumnDef,
  type ColumnSizingState,
} from '@tanstack/react-table';

const CHAR_PX = 8;
const CELL_PAD = 24;
const MIN_COL_W = 60;
const MAX_COL_W = 300;

type ColType = 'number' | 'text';

function measureWidth(strings: string[]): number {
  const maxLen = strings.reduce((m, s) => Math.max(m, s.length), 0);
  return Math.min(MAX_COL_W, Math.max(MIN_COL_W, maxLen * CHAR_PX + CELL_PAD));
}

// Scan non-null values; treat column as numeric only if every non-null cell is a JS number
function inferColType(rows: unknown[][], j: number): ColType {
  let seen = false;
  for (const row of rows) {
    const v = row[j];
    if (v == null) continue;
    seen = true;
    if (typeof v !== 'number') return 'text';
  }
  return seen ? 'number' : 'text';
}

interface DataTableProps {
  columns: string[];
  rows: unknown[][];
}

export default function DataTable({ columns, rows }: DataTableProps) {
  const [colSizing, setColSizing] = useState<ColumnSizingState>({});

  const colTypes = useMemo<ColType[]>(
    () => columns.map((_, j) => inferColType(rows, j)),
    [columns, rows],
  );

  const colDefs = useMemo<ColumnDef<unknown[]>[]>(
    () =>
      columns.map((col, j) => ({
        id: `c${j}`,
        header: col,
        accessorFn: (row: unknown[]) => row[j],
        size: measureWidth([
          col,
          ...rows.map((r) => (r[j] == null ? 'NULL' : String(r[j]))),
        ]),
        minSize: MIN_COL_W,
        maxSize: MAX_COL_W,
      })),
    [columns, rows],
  );

  const table = useReactTable({
    data: rows,
    columns: colDefs,
    state: { columnSizing: colSizing },
    onColumnSizingChange: setColSizing,
    getCoreRowModel: getCoreRowModel(),
    columnResizeMode: 'onChange',
  });

  const totalW = table.getTotalSize();

  // border-separate + borderSpacing:0 instead of border-collapse so that sticky
  // headers keep their bottom border while scrolling (collapse shares the border
  // with the first body row which disappears under the sticky element).
  //
  // Only border-r and border-b on cells — the outer editor frame already provides
  // the left/right/top edges, so adding border-l/border-t would double them up.
  return (
    <div className="overflow-auto max-h-[400px]">
      <table
        className="border-separate font-mono text-[12.5px] bg-bg"
        style={{ tableLayout: 'fixed', width: '100%', minWidth: totalW, borderSpacing: 0 }}
      >
        <colgroup>
          {table.getHeaderGroups()[0].headers.map((h) => (
            <col key={h.id} style={{ width: h.getSize() }} />
          ))}
          <col />
        </colgroup>

        <thead>
          <tr>
            {table.getHeaderGroups()[0].headers.map((header, j) => (
              <th
                key={header.id}
                className={`sticky top-0 z-10 font-semibold px-3 py-[7px] text-ink3 uppercase text-[10.5px] tracking-[0.10em] border-r border-b border-dashed border-rule-soft bg-bg2 select-none relative ${
                  colTypes[j] === 'number' ? 'text-right' : 'text-left'
                }`}
              >
                {flexRender(header.column.columnDef.header, header.getContext())}
                {/* Drag handle — thin strip on the right edge of each header */}
                <div
                  onMouseDown={header.getResizeHandler()}
                  onTouchStart={header.getResizeHandler()}
                  className={`absolute top-0 right-0 h-full w-[5px] cursor-col-resize touch-none select-none transition-colors ${
                    header.column.getIsResizing() ? 'bg-accent' : 'bg-transparent hover:bg-rule'
                  }`}
                />
              </th>
            ))}
            {/* Filler: extends the header row background with just a bottom border */}
            <th className="sticky top-0 z-10 border-b border-dashed border-rule-soft bg-bg2" />
          </tr>
        </thead>

        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td
                colSpan={columns.length + 1}
                className="px-3 py-3 text-ink3 border-b border-dashed border-rule-soft"
              >
                no rows returned
              </td>
            </tr>
          ) : (
            table.getRowModel().rows.map((row) => (
              <tr key={row.id} className="hover:bg-bg2 transition-colors">
                {row.getVisibleCells().map((cell, j) => {
                  const val = cell.getValue<unknown>();
                  return (
                    <td
                      key={cell.id}
                      className={`px-3 py-[6px] overflow-hidden text-ellipsis whitespace-nowrap border-r border-b border-dashed border-rule-soft ${
                        colTypes[j] === 'number' ? 'text-right text-syn-num' : 'text-ink'
                      }`}
                    >
                      {val == null ? (
                        <span className="text-ink3">NULL</span>
                      ) : (
                        String(val)
                      )}
                    </td>
                  );
                })}
                {/* Filler: continues the row's bottom border into empty space */}
                <td className="border-b border-dashed border-rule-soft" />
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
