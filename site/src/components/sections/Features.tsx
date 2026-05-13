export default function LayerSection() {
  return (
    <section id="layers" className="py-[var(--row)] border-b border-rule">
      <div className="max-w-[1280px] mx-auto px-[var(--gutter)]">
        <div className="lg:grid lg:grid-cols-[280px_1fr] lg:gap-16 lg:items-start">
          <header className="mb-9 lg:mb-0 lg:sticky lg:top-8">
            <pre className="font-mono text-[clamp(10px,1.1vw,13px)] leading-[1.1] text-ink mb-[18px]">
              <span className="hi">## 02 ─</span>
              {" internal/layers ─────────────────"}
            </pre>
            <p className="text-[14px] text-ink2 m-0 mb-5">
              This is my roadmap: I’m building each layer to be plug-and-play,
              like LEGO, so anyone can snap pieces together and shape a database
              that feels like their own.
            </p>

            <p className="text-[14px] text-ink2 m-0 mb-5">
              It’s also my internal reference and a very public record of
              progress. It will definitely change a lot—because, honestly, I’m
              still figuring things out as I go.
            </p>
          </header>

          <div className="flex flex-col items-stretch sm:items-center">
            <Layer label="Dialect + Parser">
              <LayerItem
                title="MySQL Dialect"
                description="mostly compatible"
                progress={0}
                width="w-full sm:w-56"
              />
              <LayerItem
                title="PostgreSQL Dialect"
                description="partial support"
                progress={0}
                width="w-full sm:w-44"
              />
              <LayerItem
                title="SQLite Dialect"
                description="basic support"
                progress={0}
                width="w-full sm:w-40"
              />
            </Layer>

            <FlowArrow />

            <Layer label="Planner">
              <LayerItem
                title="Rule-Based Planner"
                description="heuristic rewrites"
                progress={1}
                width="w-full sm:w-48"
              />
              <LayerItem
                title="Cost-Based Optimizer"
                description="statistics-driven"
                progress={0}
                width="w-full sm:w-56"
              />
            </Layer>

            <FlowArrow />

            <Layer label="Transaction">
              <LayerItem
                title="Single-Writer"
                description="serializable isolation"
                progress={2}
                width="w-full sm:w-52"
              />
              <LayerItem
                title="MVCC"
                description="snapshot reads"
                progress={0}
                width="w-full sm:w-44"
              />
            </Layer>

            <FlowArrow />

            <Layer label="Buffer Pool">
              <LayerItem
                title="LRU"
                description="least-recently-used eviction"
                progress={4}
                width="w-full sm:w-52"
              />
              <LayerItem
                title="Clock"
                description="approximate LRU, lower overhead"
                progress={0}
                width="w-full sm:w-40"
              />
              <LayerItem
                title="ARC"
                description="adaptive replacement cache"
                progress={0}
                width="w-full sm:w-44"
              />
            </Layer>

            <FlowArrow />

            <Layer label="Write-Ahead Log">
              <LayerItem
                title="WAL Manager"
                description="crash-safe commit records"
                progress={2}
                width="w-full sm:w-64"
              />
            </Layer>

            <FlowArrow />

            <Layer label="Storage Backend">
              <LayerItem
                title="Local File"
                description=".db file on disk"
                progress={3}
                width="w-full sm:w-44"
              />
              <LayerItem
                title="Remote / S3"
                description="object storage backend"
                progress={0}
                width="w-full sm:w-52"
              />
              <LayerItem
                title="In-Memory"
                description="ephemeral, no persistence"
                progress={2}
                width="w-full sm:w-40"
              />
            </Layer>
          </div>
        </div>
      </div>
    </section>
  );
}

function FlowArrow() {
  return (
    <div className="font-mono text-ink3 text-[13px] leading-none py-0.5 text-center">
      <div>│</div>
      <div>▼</div>
    </div>
  );
}

function Layer({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="w-full sm:w-auto">
      <div className="font-mono text-[11px] text-ink3 mb-1.5 flex items-center gap-1.5">
        <span className="text-accent">──</span>
        <span className="text-ink2">{label}</span>
        <span className="hidden sm:block h-px flex-1 border-b border-dashed border-rule-soft min-w-4" />
      </div>
      <div className="flex flex-col sm:flex-row gap-2">{children}</div>
    </div>
  );
}

function LayerItem({
  title,
  description,
  progress,
  width,
}: {
  title: string;
  description: string;
  progress: number;
  width: string;
}) {
  const planned = progress === 0;

  return (
    <div
      className={`font-mono ${width} px-3 py-2.5 border bg-bg relative ${
        planned ? "border-dashed border-rule-soft" : "border-rule"
      }`}
    >
      <div
        className={`text-[12px] font-medium mb-0.5 ${planned ? "text-ink3" : "text-ink"}`}
      >
        {title}
      </div>
      <div className="text-[11px] text-ink3 mb-2">{description}</div>
      <div className="text-[11px] flex items-center gap-2">
        <span className={planned ? "text-ink3" : "text-accent"}>
          {"●".repeat(progress)}
          {"○".repeat(5 - progress)}
        </span>
        {planned && <span className="text-ink3">planned</span>}
      </div>
    </div>
  );
}
