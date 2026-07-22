import { Accessibility, MonitorPlay, Check } from "lucide-react";
import Reveal from "../components/Reveal";

const PERMS = [
  {
    icon: Accessibility,
    title: "Accessibility",
    tag: "required",
    body: "Needed for all UI automation. macOS prompts on first use — or grant it in System Settings → Privacy & Security → Accessibility.",
  },
  {
    icon: MonitorPlay,
    title: "Screen Recording",
    tag: "screenshots only",
    body: "Needed only for capture. If it's missing when you request a screenshot, macbeth automatically opens the correct System Settings pane.",
  },
];

const REQS = ["macOS 14 (Sonoma) or later", "Node.js 20+", "Swift 6.0+ to build from source", "Universal daemon binary: arm64 + x86_64"];

export default function Permissions() {
  return (
    <section id="permissions" className="border-y border-[#ece6ee] bg-[#fbfafc]">
      <div className="section-shell">
        <div className="grid items-start gap-10 lg:grid-cols-2 lg:gap-14">
          <Reveal>
            <span className="eyebrow-pill mb-4">Permissions</span>
            <h2 className="mb-3 text-[clamp(24px,3.4vw,34px)] font-extrabold leading-[1.2] tracking-[-0.03em]">
              Local daemon, scoped permissions
            </h2>
            <p className="mb-6 text-[15.5px] leading-[1.65] text-[#5a5460]">
              The client starts or reuses a local Swift daemon. Nothing is installed as a login item,
              and Screen Recording is needed only when a workflow requests capture or window OCR.
            </p>
            <div className="space-y-3.5">
              {PERMS.map((p) => (
                <div key={p.title} className="flex gap-4 rounded-2xl border border-[#ece6ee] bg-white p-5">
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-[#f8eef0] text-[#61202f]">
                    <p.icon size={18} strokeWidth={2.1} />
                  </div>
                  <div>
                    <div className="mb-1 flex items-center gap-2">
                      <span className="text-[14px] font-bold">{p.title}</span>
                      <span className="rounded-full bg-[#f8eef0] px-2 py-0.5 text-[10.5px] font-bold uppercase tracking-[0.08em] text-[#8b3342]">
                        {p.tag}
                      </span>
                    </div>
                    <p className="text-[13px] leading-[1.55] text-[#5a5460]">{p.body}</p>
                  </div>
                </div>
              ))}
            </div>
          </Reveal>

          <Reveal delay={140}>
            <div className="rounded-2xl border border-[#ece6ee] bg-white p-6 sm:p-7">
              <h3 className="mb-4 text-[15px] font-bold">Requirements</h3>
              <ul className="mb-6 space-y-3">
                {REQS.map((r) => (
                  <li key={r} className="flex items-center gap-3 text-[13.5px] text-[#3d3644]">
                    <span className="flex h-5 w-5 items-center justify-center rounded-full bg-[#f8eef0]">
                      <Check size={12} strokeWidth={3} className="text-[#61202f]" />
                    </span>
                    {r}
                  </li>
                ))}
              </ul>
              <div className="rounded-xl border border-[#ece6ee] bg-[#fbfafc] p-4">
                <div className="mb-1.5 text-[12px] font-bold uppercase tracking-[0.1em] text-[#61202f]">
                  Process lifecycle
                </div>
                <p className="text-[12.5px] leading-[1.6] text-[#5a5460]">
                  Simple scripts exit when their work is done, while the daemon may stay warm for fast
                  follow-up runs. A managed client closes a daemon process that it started with close().
                </p>
              </div>
            </div>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
