import { useState } from "react";
import { Check, Copy, Github } from "lucide-react";
import Reveal from "../components/Reveal";

export default function Cta() {
  const [copied, setCopied] = useState(false);
  const cmd = "claude mcp add macbeth -- npx -y macbeth";

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(cmd);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch { /* noop */ }
  };

  return (
    <section className="grain-dark">
      <div className="section-shell py-24 text-center">
        <Reveal>
          <span className="mb-5 inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-3.5 py-1.5 text-[11.5px] font-bold uppercase tracking-[0.12em] text-[#d9a3ae]">
            Open source · MIT
          </span>
          <h2 className="mx-auto mb-4 max-w-[20ch] text-[clamp(26px,4vw,40px)] font-extrabold leading-[1.15] tracking-[-0.03em] text-white">
            Give your agent a Mac interface
          </h2>
          <p className="mx-auto mb-9 max-w-[52ch] text-[15.5px] leading-[1.6] text-[#b7adbf]">
            Add one local MCP server, grant only the permissions your workflow needs, and start
            with a read-only inspection of an application you trust.
          </p>
          <div className="mb-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <button
              onClick={copy}
              className="group flex max-w-full items-center gap-3 overflow-x-auto whitespace-nowrap rounded-xl bg-white px-5 py-3 font-mono text-[11px] text-[#1a1520] shadow-[0_16px_40px_-12px_rgba(0,0,0,0.5)] transition-transform hover:-translate-y-0.5 sm:text-[14px]"
            >
              <span className="text-[#8b3342]">$</span>
              {cmd}
              {copied ? <Check size={15} className="text-green-600" /> : <Copy size={15} className="text-[#8b8296] transition-colors group-hover:text-[#61202f]" />}
            </button>
            <a
              href="https://github.com/wende/macbeth"
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-2.5 rounded-xl border border-white/20 px-5 py-3 text-[14px] font-semibold text-white transition-colors hover:bg-white/10"
            >
              <Github size={16} />
              wende/macbeth
            </a>
          </div>
          <p className="font-mono text-[12px] text-[#7d7386]">
            macOS 14+ · Node 20+ · universal binary (arm64 + x86_64)
          </p>
        </Reveal>
      </div>
    </section>
  );
}
