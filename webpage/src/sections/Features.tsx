import {
  AppWindow, MousePointerClick, Camera, ListTree,
} from "lucide-react";
import Reveal from "../components/Reveal";

const FEATURES = [
  {
    icon: AppWindow,
    title: "Control the tools you work in",
    body: "Combine structured controls with keyboard, menu, screenshot, and OCR fallbacks in Logic Pro and parts of Unity.",
  },
  {
    icon: MousePointerClick,
    title: "Use applications without APIs",
    body: "Use generic Electron support with apps such as HEY; results depend on the accessibility tree and version.",
  },
  {
    icon: Camera,
    title: "Visual fallback",
    body: "Capture a target window and run local Vision OCR when accessibility data is incomplete.",
  },
  {
    icon: ListTree,
    title: "Structured UI trees",
    body: "Give agents named controls, values, state, and hierarchy instead of pixels alone.",
  },
];

export default function Features() {
  return (
    <section id="features" className="section-shell">
      <Reveal className="mb-12 text-center">
        <span className="eyebrow-pill mb-4">Features</span>
        <h2 className="mx-auto mb-3 max-w-[22ch] text-[clamp(24px,3.4vw,34px)] font-extrabold leading-[1.2] tracking-[-0.03em]">
          Structured when possible, visual when necessary
        </h2>
        <p className="mx-auto max-w-[56ch] text-[15.5px] text-[#5a5460]">
          Macbeth uses macOS accessibility primitives first, then keeps screenshots, OCR, menus,
          keyboard input, AppleScript, and Shortcuts available for difficult surfaces.
        </p>
      </Reveal>

      <div className="mx-auto grid max-w-[900px] grid-cols-1 gap-4 sm:grid-cols-2">
        {FEATURES.map((f, i) => (
          <Reveal key={f.title} delay={(i % 2) * 80}>
            <div className="group flex h-full items-start gap-4 rounded-2xl border border-[#ece6ee] bg-[#fbfafc] p-5 transition-all duration-300 hover:-translate-y-1 hover:border-[#d9c3ca] hover:shadow-[0_16px_40px_-16px_rgba(97,32,47,0.25)]">
              <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[10px] bg-[#f8eef0] text-[#61202f] transition-colors group-hover:bg-[#61202f] group-hover:text-white">
                <f.icon size={17} strokeWidth={2.1} />
              </div>
              <div>
                <h3 className="mb-1 text-[14.5px] font-bold tracking-[-0.01em]">{f.title}</h3>
                <p className="text-[13px] leading-[1.55] text-[#5a5460]">{f.body}</p>
              </div>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
