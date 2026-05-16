const DATA_URL = "https://invisal.github.io/pagerdb/sqllogictest.json";
const numberFormat = new Intl.NumberFormat("en-US");

export type CoverageFile = {
  path: string;
  passed: number;
  failed: number;
};

export type CoveragePayload = {
  generated_at: number;
  commit: string;
  summary: {
    passed: number;
    failed: number;
    files: number;
  };
  files: CoverageFile[];
};

function toPercent(passed: number, failed: number) {
  const total = passed + failed;
  if (total === 0) return 0;
  return (passed / total) * 100;
}

function formatPercent(value: number) {
  return `${value.toFixed(2)}%`;
}

function formatNumber(value: number) {
  return numberFormat.format(value);
}

function formatDate(unixSeconds: number) {
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(unixSeconds * 1000));
}

export default function SqllogictestCoverage({
  payload,
}: {
  payload: CoveragePayload;
}) {
  const overallPercent = toPercent(
    payload.summary.passed,
    payload.summary.failed,
  );
  const files = [...payload.files].sort((left, right) => {
    const failedDelta = right.failed - left.failed;
    if (failedDelta !== 0) return failedDelta;

    const totalDelta =
      right.passed + right.failed - (left.passed + left.failed);
    if (totalDelta !== 0) return totalDelta;

    return left.path.localeCompare(right.path);
  });

  return (
    <section className="max-w-[1280px] mx-auto px-[var(--gutter)] py-[clamp(28px,6vw,72px)]">
      <div className="mb-10">
        <div className="flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
          <div className="max-w-[760px]">
            <div className="font-mono text-[11px] uppercase tracking-[0.10em] text-ink3 mb-3">
              coverage report
            </div>
            <h1 className="m-0 text-[clamp(28px,3.5vw,44px)] leading-[1.05] tracking-[-0.03em] font-normal text-ink">
              sqllogictest
            </h1>
            <p className="mt-5 mb-0 text-ink2 text-[15px] leading-[1.8] max-w-[68ch]">
              PagerDB runs against the{" "}
              <a href="https://sqlite.org/sqllogictest/dir?ci=tip&name=test">
                SQLite project's sqllogictest suite
              </a>{" "}
              — thousands of query-and-result assertions covering a wide surface
              of standard SQL. The results reflect whether the engine computes
              the right answer. They say nothing about performance, durability,
              or concurrency.
            </p>
          </div>
        </div>
      </div>

      <div className="border border-rule bg-bg2 p-5 sm:p-8">
        <div className="flex flex-col gap-6 lg:grid lg:grid-cols-[minmax(0,1.5fr)_320px] lg:items-start">
          <div>
            <div className="flex items-end justify-between gap-4 mb-4">
              <div className="font-mono text-[11px] uppercase tracking-[0.10em] text-ink3">
                overall progress
              </div>
              <div className="text-[clamp(32px,5vw,58px)] leading-none font-semibold tracking-[-0.05em] text-ink">
                {formatPercent(overallPercent)}
              </div>
            </div>

            <div className="h-8 sm:h-10 border border-rule overflow-hidden bg-bg">
              <div
                className="h-full bg-accent transition-[width] duration-500"
                style={{ width: `${overallPercent}%` }}
              />
            </div>

            <div className="mt-4 grid gap-3 sm:grid-cols-3">
              <StatCard
                label="passed"
                value={formatNumber(payload.summary.passed)}
                tone="text-syn-str"
              />
              <StatCard
                label="failed"
                value={formatNumber(payload.summary.failed)}
                tone="text-accent"
              />
              <StatCard
                label="tracked files"
                value={formatNumber(payload.summary.files)}
                tone="text-ink"
              />
            </div>
          </div>

          <div className="border border-dashed border-rule-soft bg-bg p-4 sm:p-5">
            <div className="font-mono text-[11px] uppercase tracking-[0.10em] text-ink3 mb-4">
              report metadata
            </div>
            <dl className="grid grid-cols-[96px_1fr] gap-y-3 gap-x-4 m-0 text-[13px] leading-[1.6]">
              <dt className="font-mono uppercase tracking-[0.08em] text-ink3">
                updated
              </dt>
              <dd className="m-0 text-ink">
                {formatDate(payload.generated_at)}
              </dd>
              <dt className="font-mono uppercase tracking-[0.08em] text-ink3">
                commit
              </dt>
              <dd className="m-0 text-ink break-all">{payload.commit}</dd>
              <dt className="font-mono uppercase tracking-[0.08em] text-ink3">
                source
              </dt>
              <dd className="m-0 text-ink break-all">{DATA_URL}</dd>
            </dl>
          </div>
        </div>
      </div>

      <div className="mt-8 border border-rule overflow-hidden bg-bg2">
        <div className="p-5 sm:p-6 border-b border-dashed border-rule-soft flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <div className="font-mono text-[11px] uppercase tracking-[0.10em] text-ink3 mb-2">
              file breakdown
            </div>
            <h2 className="m-0 text-[clamp(24px,4vw,40px)] leading-[1] tracking-[-0.04em] text-ink">
              coverage by test file
            </h2>
          </div>
          <p className="m-0 text-[13px] leading-[1.7] text-ink2 max-w-[54ch]">
            Sorted by highest failed count first. Each bar shows the share of
            statements that currently pass within that file.
          </p>
        </div>

        <div className="max-h-[72vh] overflow-auto">
          <table className="w-full border-separate border-spacing-0 font-mono text-[12px]">
            <thead>
              <tr>
                <th className="sticky top-0 z-10 bg-bg px-4 py-3 text-left uppercase tracking-[0.10em] text-ink3 text-[10px] border-b border-dashed border-rule-soft">
                  file
                </th>
                <th className="sticky top-0 z-10 bg-bg px-4 py-3 text-left uppercase tracking-[0.10em] text-ink3 text-[10px] border-b border-dashed border-rule-soft">
                  coverage
                </th>
                <th className="sticky top-0 z-10 bg-bg px-4 py-3 text-right uppercase tracking-[0.10em] text-ink3 text-[10px] border-b border-dashed border-rule-soft">
                  passed
                </th>
                <th className="sticky top-0 z-10 bg-bg px-4 py-3 text-right uppercase tracking-[0.10em] text-ink3 text-[10px] border-b border-dashed border-rule-soft">
                  failed
                </th>
                <th className="sticky top-0 z-10 bg-bg px-4 py-3 text-right uppercase tracking-[0.10em] text-ink3 text-[10px] border-b border-dashed border-rule-soft">
                  total
                </th>
              </tr>
            </thead>
            <tbody>
              {files.map((file) => {
                const total = file.passed + file.failed;
                const percent = toPercent(file.passed, file.failed);

                return (
                  <tr key={file.path} className="hover:bg-bg transition-colors">
                    <td className="px-4 py-3 align-top border-b border-dashed border-rule-soft text-ink break-all">
                      {file.path}
                    </td>
                    <td className="px-4 py-3 align-top border-b border-dashed border-rule-soft min-w-[220px]">
                      <div className="flex items-center gap-3">
                        <div className="h-2.5 flex-1 border border-rule-soft bg-bg overflow-hidden">
                          <div
                            className="h-full bg-accent"
                            style={{ width: `${percent}%` }}
                          />
                        </div>
                        <span className="text-ink min-w-[62px] text-right tabular-nums">
                          {formatPercent(percent)}
                        </span>
                      </div>
                    </td>
                    <td className="px-4 py-3 align-top border-b border-dashed border-rule-soft text-right text-syn-str tabular-nums">
                      {formatNumber(file.passed)}
                    </td>
                    <td className="px-4 py-3 align-top border-b border-dashed border-rule-soft text-right text-accent tabular-nums">
                      {formatNumber(file.failed)}
                    </td>
                    <td className="px-4 py-3 align-top border-b border-dashed border-rule-soft text-right text-ink3 tabular-nums">
                      {formatNumber(total)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}

function StatCard({
  label,
  value,
  tone,
}: {
  label: string;
  value: string;
  tone: string;
}) {
  return (
    <div className="border border-dashed border-rule-soft bg-bg px-4 py-4">
      <div className="font-mono text-[10px] uppercase tracking-[0.10em] text-ink3 mb-2">
        {label}
      </div>
      <div
        className={`text-[26px] leading-none font-semibold tracking-[-0.04em] ${tone}`}
      >
        {value}
      </div>
    </div>
  );
}
