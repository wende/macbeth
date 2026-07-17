import {
  Accordion, AccordionContent, AccordionItem, AccordionTrigger,
} from "@/components/ui/accordion";
import Reveal from "../components/Reveal";

const FAQS = [
  {
    q: "Do I need to manage a background service?",
    a: "No. The TypeScript client auto-spawns the Swift daemon (macbethd) as a subprocess and shuts it down on close. Simple scripts exit cleanly when the work is done, and the daemon stays warm in the background for fast subsequent runs.",
  },
  {
    q: "Can it drive Electron apps like Slack and VS Code?",
    a: "Yes — with the same locator API as native apps. On connect, macbeth sets AXManualAccessibility to switch Chromium's accessibility tree on, then waits for web content to appear. click and fill have Electron-aware strategies (auto / ax / mouse and auto / ax / keyboard) that synthesize real input events when frameworks like React need them.",
  },
  {
    q: "How do LLM agents use it?",
    a: "macbeth includes an MCP server — add it to your Claude Code config with \"npx macbeth\" and the agent gets tools like connect_app, query_tree, click, fill, screenshot, and extract_text, plus bundled app skills for Calendar, Mail, Safari, System Settings, and more. An interaction glow shows exactly which window is being controlled.",
  },
  {
    q: "What happens when an element isn't there yet?",
    a: "All action methods auto-wait: they poll for the target element until it appears or the timeout expires (30s by default, tunable per call). Locators are lazy and immutable, so chains re-resolve cleanly even after Electron re-renders invalidate element handles.",
  },
  {
    q: "Can I read text from apps with thin accessibility trees?",
    a: "Yes. Screenshots use ScreenCaptureKit for high-fidelity window capture, and extract_text runs Vision-based OCR on a window or supplied PNG — both with live regression coverage in the test-harness suite.",
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
