import Logo from "../components/Logo";

const FEATURES = [
  {
    title: "One control layer",
    body: "Inspect and operate native AppKit and Electron interfaces through the same primitives.",
  },
  {
    title: "Bring your own agent",
    body: "Connect through MCP over stdio, with an on-screen glow for visible interactions.",
  },
  {
    title: "Structured + visual",
    body: "Use roles, labels, state, and auto-waiting actions, with screenshots and OCR as fallbacks.",
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
          Computer Use for macOS
        </h1>
        <p className="mx-auto mb-7 max-w-[48ch] text-[17px] leading-[1.55] text-[#5a5460]">
          Let the agent you already use inspect and operate native AppKit and Electron interfaces
          through structured UI trees, reliable actions, screenshots, OCR, and reusable skills.
        </p>

        <div className="mb-9 inline-flex max-w-full items-center gap-3 overflow-x-auto whitespace-nowrap rounded-[10px] bg-[#0f0d12] px-[18px] py-3 font-mono text-[11px] text-[#f4f1f8] shadow-[0_8px_24px_rgba(97,32,47,0.18)] sm:text-[14px]">
          <span className="text-[#c47a88]">$</span>
          <span>claude mcp add macbeth -- npx -y macbeth</span>
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
