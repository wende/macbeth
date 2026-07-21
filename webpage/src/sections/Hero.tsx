import Logo from "../components/Logo";

const FEATURES = [
  {
    title: "Complex Mac tools",
    body: "Combine controls, menus, keyboard input, and visual fallbacks in Logic Pro and thin-tree surfaces such as Unity.",
  },
  {
    title: "Apps without APIs",
    body: "Work through Electron interfaces such as HEY using generic control—not a dedicated service integration.",
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
          Open-source Computer Use for macOS
        </h1>
        <p className="mx-auto mb-3 max-w-[48ch] text-[19px] font-bold leading-[1.45] text-[#1a1520]">
          Give the agent you already use hands and eyes on your Mac.
        </p>
        <p className="mx-auto mb-3 max-w-[52ch] text-[16px] leading-[1.55] text-[#5a5460]">
          See and operate native AppKit and Electron applications through MCP or TypeScript.
        </p>
        <p className="mx-auto mb-5 max-w-[58ch] text-[14px] leading-[1.55] text-[#8b8296]">
          Structured UI access when possible. Screenshots and OCR when necessary. Think Playwright
          for your entire Mac.
        </p>

        <div className="mb-6 flex flex-wrap items-center justify-center gap-2 text-[11px] font-semibold text-[#61202f]">
          <a href="https://www.npmjs.com/package/macbeth" target="_blank" rel="noreferrer" className="rounded-full border border-[#d9c3ca] bg-white px-3 py-1">npm v0.2.1</a>
          <span className="rounded-full border border-[#d9c3ca] bg-white px-3 py-1">MIT</span>
          <span className="rounded-full border border-[#d9c3ca] bg-white px-3 py-1">macOS 14+</span>
          <span className="rounded-full border border-[#d9c3ca] bg-white px-3 py-1">MCP server</span>
        </div>

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
