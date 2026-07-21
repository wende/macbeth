import {
  Accordion, AccordionContent, AccordionItem, AccordionTrigger,
} from "@/components/ui/accordion";
import Reveal from "../components/Reveal";

const FAQS = [
  {
    q: "Do I need to manage a background service?",
    a: "No login item is installed. The TypeScript client starts or reuses the local Swift daemon; a managed client closes a daemon process it started with close(), while a reused daemon may stay warm for fast subsequent runs.",
  },
  {
    q: "How does it handle Electron applications?",
    a: "Macbeth enables Chromium's accessibility tree, waits for web content to appear, and uses Electron-aware click and fill strategies. Results still depend on the accessibility information and custom-rendered surfaces exposed by each application version.",
  },
  {
    q: "How do LLM agents use it?",
    a: "Macbeth includes a stdio MCP server. Claude Code has a one-command setup, and other clients that can launch a stdio server can use the same npx entry point. The agent gets inspection, action, screenshot, OCR, system-integration, and skill tools.",
  },
  {
    q: "What happens when an element isn't there yet?",
    a: "All action methods auto-wait: they poll for the target element until it appears or the timeout expires (30s by default, tunable per call). Locators are lazy and immutable, so chains re-resolve cleanly even after Electron re-renders invalidate element handles.",
  },
  {
    q: "Can I read text from apps with thin accessibility trees?",
    a: "Screenshots use ScreenCaptureKit for target-window capture, and extract_text runs local Vision OCR on a window or supplied PNG. Screen Recording permission is required for window capture.",
  },
  {
    q: "What does it cost, and what's the license?",
    a: "macbeth is free and open source under the MIT license. Requirements are macOS 14 (Sonoma) or later and Node.js 20+; Swift 6.0+ is only needed to build the daemon from source.",
  },
];

export default function Faq() {
  return (
    <section id="faq" className="section-shell">
      <Reveal className="mx-auto max-w-[760px]">
        <div className="mb-10 text-center">
          <span className="eyebrow-pill mb-4">FAQ</span>
          <h2 className="mb-3 text-[clamp(24px,3.4vw,34px)] font-extrabold leading-[1.2] tracking-[-0.03em]">
            Questions, answered
          </h2>
        </div>
        <Accordion type="single" collapsible className="w-full">
          {FAQS.map((f, i) => (
            <AccordionItem
              key={f.q}
              value={`item-${i}`}
              className="mb-2.5 overflow-hidden rounded-xl border border-[#ece6ee] bg-[#fbfafc] px-5 transition-colors data-[state=open]:border-[#d9c3ca] data-[state=open]:bg-white"
            >
              <AccordionTrigger className="py-4 text-left text-[14px] font-semibold text-[#1a1520] hover:no-underline [&[data-state=open]]:text-[#61202f]">
                {f.q}
              </AccordionTrigger>
              <AccordionContent className="pb-4 text-[13.5px] leading-[1.65] text-[#5a5460]">
                {f.a}
              </AccordionContent>
            </AccordionItem>
          ))}
        </Accordion>
      </Reveal>
    </section>
  );
}
