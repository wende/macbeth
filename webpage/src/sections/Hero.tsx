import Logo from "../components/Logo";

const FEATURES = [
  {
    title: "Native + Electron",
    body: "Same locator API across AppKit and Chromium apps — Slack, VS Code, Discord included.",
  },
  {
    title: "MCP for agents",
    body: "Ship tool calls to Claude & friends, with an on-screen interaction glow.",
  },
  {
    title: "Playwright-style DX",
    body: "Lazy chainable locators, smart click/fill strategies, screenshots & OCR.",
  },
];

export default function Hero() {
  return (
    <section id="top" className="relative overflow-hidden">
      {/* soft backdrop */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            "radial-gradient(ellipse 60% 45% at 50% -5%, rgba(139,51,66,0.09), transparent 65%), radial-gradient(ellipse 40% 35% at 85% 30%, rgba(97,32,47,0.05), transparent 60%)",
        }}
      />
      <div className="relative mx-auto max-w-[920px] px-6 pb-16 pt-[132px] text-center sm:px-10">
        <Logo className="mx-auto mb-7 block h-auto w-[min(380px,88%)]" />

        <h1 className="mx-auto mb-3.5 max-w-[18ch] text-[clamp(28px,4.2vw,42px)] font-extrabold leading-[1.15] tracking-[-0.035em]">
          Playwright for macOS
        </h1>
        <p className="mx-auto mb-7 max-w-[48ch] text-[17px] leading-[1.55] text-[#5a5460]">
          Chainable locators, auto-waiting, screenshots, OCR, and an MCP server — so TypeScript
          scripts and LLM agents can drive native AppKit and Electron apps alike.
        </p>

        <div className="mb-9 inline-flex items-center gap-3 rounded-[10px] bg-[#0f0d12] px-[18px] py-3 font-mono text-[14px] text-[#f4f1f8] shadow-[0_8px_24px_rgba(97,32,47,0.18)]">
          <span className="text-[#c47a88]">$</span>
          <span>npm install macbeth</span>
        </div>

        <div className="mx-auto grid max-w-[820px] grid-cols-1 gap-4 text-left sm:grid-cols-3">
          {FEATURES.map((f) => (
            <div key={f.title} className="rounded-xl border border-[#ece6ee] bg-[#fbfafc] p-4">
              <strong className="mb-1 block text-[13px] font-bold text-[#61202f]">{f.title}</strong>
              <span className="text-[13px] leading-[1.45] text-[#5a5460]">{f.body}</span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
