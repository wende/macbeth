import { useEffect, useRef, useState } from "react";
import { Camera, MessageSquare, RotateCcw, SlidersHorizontal } from "lucide-react";
import Reveal from "../components/Reveal";
import ChatPanel, { type ChatMsg, type ChatMsgInput } from "../components/demo/ChatPanel";
import Desktop, { type ScenarioId } from "../components/demo/Desktop";

/* ------------------------------------------------------------------ */
/* scenario scripts                                                    */
/* ------------------------------------------------------------------ */

interface SimApi {
  cancelled: () => boolean;
  sleep: (ms: number) => Promise<void>;
  say: (text: string) => Promise<void>;
  note: (text: string) => Promise<void>;
  tool: (name: string, args: string, result: string, work?: () => Promise<void>) => Promise<void>;
  glow: (on: boolean) => Promise<void>;
  moveTo: (elId: string) => Promise<void>;
  click: (elId: string) => Promise<void>;
  type: (target: "slack-input", text: string) => Promise<void>;
  scan: () => Promise<void>;
  ocr: () => Promise<void>;
  shotCard: () => Promise<void>;
  sendSlack: () => Promise<void>;
  flipToggle: (id: "nightshift" | "truetone" | "hotcorners") => Promise<void>;
  flipCheckbox: () => Promise<void>;
  dragSlider: (to: number) => Promise<void>;
  showToast: (text: string) => Promise<void>;
}

const SCENARIOS: Record<
  ScenarioId,
  { label: string; hint: string; icon: typeof Camera; run: (api: SimApi) => Promise<void> }
> = {
  settings: {
    label: "Tune the display",
    hint: "System Settings · slider + toggles",
    icon: SlidersHorizontal,
    run: async (api) => {
      await api.say("Dim my screen to 40%, turn off True Tone, and switch on Night Shift.");
      await api.tool("connect_app", '"System Settings"', "Connected — window outlined", async () => {
        await api.glow(true);
      });
      await api.tool("click", '"Automatically adjust brightness"', "Toggled off", async () => {
        await api.click("auto-brightness-switch");
        await api.flipCheckbox();
      });
      await api.tool(
        "click",
        '"Brightness", { strategy: "mouse" }',
        "Dragged to 40%",
        async () => {
          await api.dragSlider(0.4);
        }
      );
      await api.tool("click", '"True Tone"', "Toggled off", async () => {
        await api.click("truetone-switch");
        await api.flipToggle("truetone");
      });
      await api.tool("click", '"Night Shift"', "Toggled on", async () => {
        await api.click("nightshift-switch");
        await api.flipToggle("nightshift");
        await api.showToast("Night Shift — on until sunrise");
      });
      await api.note(
        "Done — brightness is at 40%, True Tone is off, and Night Shift will stay on until sunrise."
      );
    },
  },
  slack: {
    label: "Slack message",
    hint: "Electron · fill + click",
    icon: MessageSquare,
    run: async (api) => {
      await api.say("Show a release note in the simulated #engineering channel.");
      await api.tool("connect_app", '"Slack"', "Connected — Electron app, web content ready", async () => {
        await api.glow(true);
      });
      await api.tool(
        "fill",
        '"Message #engineering", "…"',
        "Message field filled",
        async () => {
          await api.moveTo("slack-input");
          await api.type("slack-input", "Macbeth is out — open-source Computer Use for macOS.");
        }
      );
      await api.tool("click", '"Send"', "Send selected in the simulated interface", async () => {
        await api.click("send");
        await api.sendSlack();
      });
      await api.note("Message shown in the simulated channel.");
    },
  },
  shot: {
    label: "Screenshot + OCR",
    hint: "Notes · capture + extract_text",
    icon: Camera,
    run: async (api) => {
      await api.say("Screenshot my Notes window and read the text in it.");
      await api.tool("connect_app", '"Notes"', "Connected — window outlined", async () => {
        await api.glow(true);
      });
      await api.tool("screenshot", "", "Captured notes-window.png", async () => {
        await api.scan();
        await api.shotCard();
      });
      await api.tool("extract_text", "window", "4 text blocks recognized", async () => {
        await api.ocr();
      });
      await api.note(
        'Found: "macbeth release checklist — notarize daemon binary, prepare npm release, update bundled app skills."'
      );
    },
  },
};

/* ------------------------------------------------------------------ */
/* section                                                             */
/* ------------------------------------------------------------------ */

const RM =
  typeof window !== "undefined" &&
  window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;

const INITIAL: ScenarioId = (() => {
  if (typeof window === "undefined") return "settings";
  const q = new URLSearchParams(window.location.search).get("demo");
  return q === "slack" || q === "shot" || q === "settings" ? q : "settings";
})();

export default function Demo() {
  const [scenario, setScenario] = useState<ScenarioId>(INITIAL);
  const [runKey, setRunKey] = useState(0);
  const [messages, setMessages] = useState<ChatMsg[]>([]);
  const [glowOn, setGlowOn] = useState(false);
  const [snapOn, setSnapOn] = useState(false);
  const [scanKey, setScanKey] = useState(0);
  const [ocrOn, setOcrOn] = useState(false);
  const [typedSlack, setTypedSlack] = useState("");
  const [typingTarget, setTypingTarget] = useState<string | null>(null);
  const [sent, setSent] = useState<string[]>([]);
  const [pressedId, setPressedId] = useState<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [toggleNightShift, setToggleNightShift] = useState(false);
  const [toggleTrueTone, setToggleTrueTone] = useState(true);
  const [toggleHotCorners, setToggleHotCorners] = useState(false);
  const [autoBrightness, setAutoBrightness] = useState(true);
  const [sliderLevel, setSliderLevel] = useState(0.75);
  const [sliderDragging, setSliderDragging] = useState(false);
  const [pointer, setPointer] = useState({ x: 60, y: 380, visible: false });
  const [ripples, setRipples] = useState<{ id: number; x: number; y: number }[]>([]);
  const [finished, setFinished] = useState(false);

  const desktopRef = useRef<HTMLDivElement>(null);
  const elRefs = useRef(new Map<string, HTMLElement>());
  const msgId = useRef(0);
  const rippleId = useRef(0);
  const sliderLevelRef = useRef(0.75);
  const pointerPos = useRef({ x: 60, y: 400 });
  const pointerAnim = useRef<number | null>(null);

  const reg = (id: string) => (el: HTMLElement | null) => {
    if (el) elRefs.current.set(id, el);
    else elRefs.current.delete(id);
  };

  /* center of a registered element, relative to the desktop container */
  const centerOf = (id: string) => {
    const box = desktopRef.current?.getBoundingClientRect();
    const el = elRefs.current.get(id)?.getBoundingClientRect();
    if (!box || !el) return { x: 80, y: 80 };
    return { x: el.left - box.left + el.width / 2, y: el.top - box.top + el.height / 2 };
  };

  useEffect(() => {
    let cancelled = false;
    const speed = RM ? 0.15 : 1;
    const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms * speed));
    sliderLevelRef.current = 0.75;

    /* reset all state */
    setMessages([]);
    setGlowOn(false);
    setSnapOn(false);
    setScanKey(0);
    setOcrOn(false);
    setTypedSlack("");
    setTypingTarget(null);
    setSent([]);
    setToggleNightShift(false);
    setToggleTrueTone(true);
    setToggleHotCorners(false);
    setAutoBrightness(true);
    setSliderLevel(0.75);
    setSliderDragging(false);
    setPressedId(null);
    setToast(null);
    setRipples([]);
    setFinished(false);
    setPointer({ x: 60, y: 400, visible: false });

    const push = (m: ChatMsgInput) => {
      const id = ++msgId.current;
      setMessages((prev) => [...prev, { ...m, id } as ChatMsg]);
      return id;
    };

    /* JS-driven pointer animation — bypasses CSS transition so position updates
       apply immediately and clicks fire when the pointer actually arrives */
    const animatePointerTo = (target: { x: number; y: number }, ms: number) =>
      new Promise<void>((resolve) => {
        if (pointerAnim.current) cancelAnimationFrame(pointerAnim.current);
        const from = { ...pointerPos.current };
        const startT = performance.now();
        const step = (t: number) => {
          if (cancelled) return resolve();
          const k = Math.min(1, (t - startT) / ms);
          /* ease-out cubic */
          const e = 1 - Math.pow(1 - k, 3);
          const x = from.x + (target.x - from.x) * e;
          const y = from.y + (target.y - from.y) * e;
          pointerPos.current = { x, y };
          setPointer({ x, y, visible: true });
          if (k < 1) pointerAnim.current = requestAnimationFrame(step);
          else resolve();
        };
        pointerAnim.current = requestAnimationFrame(step);
      });

    const api: SimApi = {
      cancelled: () => cancelled,
      sleep,
      say: async (text) => {
        push({ kind: "user", text });
        await sleep(900);
      },
      note: async (text) => {
        push({ kind: "assistant", text });
        await sleep(600);
      },
      tool: async (name, args, result, work) => {
        const id = push({ kind: "tool", name, args, status: "running" });
        await sleep(450);
        if (work) await work();
        if (cancelled) return;
        setMessages((prev) =>
          prev.map((m) => (m.id === id && m.kind === "tool" ? { ...m, status: "done", result } : m))
        );
        await sleep(650);
      },
      glow: async (on) => {
        setGlowOn(on);
        await sleep(650);
      },
      moveTo: async (elId) => {
        const c = centerOf(elId);
        const dist = Math.hypot(c.x - pointerPos.current.x, c.y - pointerPos.current.y);
        const ms = Math.max(280, Math.min(720, dist * 1.6));
        await animatePointerTo(c, ms);
      },
      click: async (elId) => {
        const c = centerOf(elId);
        const dist = Math.hypot(c.x - pointerPos.current.x, c.y - pointerPos.current.y);
        const ms = Math.max(280, Math.min(720, dist * 1.6));
        await animatePointerTo(c, ms);
        if (cancelled) return;
        /* brief pause before press — reads as aim */
        await sleep(120);
        const id = ++rippleId.current;
        setRipples((prev) => [...prev, { id, x: c.x, y: c.y }]);
        /* row highlight keys off the row id, not the inner switch id */
        setPressedId(elId.replace(/-switch$/, ""));
        setTimeout(() => setRipples((prev) => prev.filter((r) => r.id !== id)), 750);
        setTimeout(() => setPressedId(null), 350);
        await sleep(380);
      },
      type: async (target, text) => {
        setTypingTarget(target);
        let acc = "";
        for (const ch of text) {
          if (cancelled) return;
          acc += ch;
          setTypedSlack(acc);
          await sleep(26);
        }
        await sleep(250);
        setTypingTarget(null);
      },
      scan: async () => {
        setScanKey((k) => k + 1);
        await sleep(1500);
        if (cancelled) return;
        setSnapOn(true);
        setTimeout(() => setSnapOn(false), 600);
        await sleep(500);
      },
      ocr: async () => {
        setOcrOn(true);
        await sleep(900);
      },
      shotCard: async () => {
        push({ kind: "shot" });
        await sleep(700);
      },
      sendSlack: async () => {
        setSent((prev) => [...prev, "Macbeth is out — open-source Computer Use for macOS."]);
        setTypedSlack("");
        await sleep(500);
      },
      flipToggle: async (id) => {
        if (id === "nightshift") setToggleNightShift((v) => !v);
        else if (id === "truetone") setToggleTrueTone((v) => !v);
        else setToggleHotCorners((v) => !v);
        await sleep(350);
      },
      flipCheckbox: async () => {
        setAutoBrightness((v) => !v);
        await sleep(350);
      },
      dragSlider: async (to) => {
        /* move to knob, then track it 1:1 while the value changes */
        const knob = elRefs.current.get("slider");
        const start = knob ? centerOf("slider") : { x: 0, y: 0 };
        const from = sliderLevelRef.current;
        const trackRect = knob?.parentElement?.getBoundingClientRect() ?? null;
        const deskLeft = desktopRef.current?.getBoundingClientRect().left ?? 0;
        const knobX = (v: number) =>
          knob && trackRect ? trackRect.left - deskLeft + v * trackRect.width : start.x;

        /* glide to the knob first */
        await animatePointerTo(start, 360);
        if (cancelled) return;
        await sleep(140);
        setSliderDragging(true);

        /* drag — rAF loop so knob and pointer update in the same frame */
        const dragMs = 620;
        const startT = performance.now();
        await new Promise<void>((resolve) => {
          const step = (t: number) => {
            if (cancelled) return resolve();
            const k = Math.min(1, (t - startT) / dragMs);
            /* ease-in-out */
            const e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
            const v = from + (to - from) * e;
            sliderLevelRef.current = v;
            setSliderLevel(v);
            const x = knobX(v);
            pointerPos.current = { x, y: start.y };
            setPointer({ x, y: start.y, visible: true });
            if (k < 1) requestAnimationFrame(step);
            else resolve();
          };
          requestAnimationFrame(step);
        });
        setSliderDragging(false);
        await sleep(180);
      },
      showToast: async (text) => {
        setToast(text);
        setTimeout(() => setToast(null), 2100);
        await sleep(700);
      },
    };

    const run = async () => {
      await sleep(500);
      await SCENARIOS[scenario].run(api);
      if (!cancelled) {
        setPointer((p) => ({ ...p, visible: false }));
        setFinished(true);
      }
    };
    run();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [scenario, runKey]);

  return (
    <section id="demo" className="border-y border-[#ece6ee] bg-[#fbfafc]">
      <div className="section-shell">
        <Reveal className="mb-8 text-center">
          <span className="eyebrow-pill mb-4">Interactive walkthrough</span>
          <h2 className="mx-auto mb-3 max-w-[22ch] text-[clamp(24px,3.4vw,34px)] font-extrabold leading-[1.2] tracking-[-0.03em]">
            See the interaction model
          </h2>
          <p className="mx-auto max-w-[56ch] text-[15.5px] text-[#5a5460]">
            This simulated interface illustrates Macbeth's tool sequence and interaction glow.
            Pick a scenario to follow each inspection, action, capture, and result.
          </p>
        </Reveal>

        <Reveal delay={80}>
          <div className="mb-5 flex flex-wrap items-center justify-center gap-2">
            {(Object.keys(SCENARIOS) as ScenarioId[]).map((id) => {
              const s = SCENARIOS[id];
              const active = scenario === id;
              return (
                <button
                  key={id}
                  onClick={() => setScenario(id)}
                  className={`flex items-center gap-2 rounded-xl border px-3.5 py-2 text-left transition-all ${
                    active
                      ? "border-[#61202f] bg-[#61202f] text-white shadow-[0_8px_20px_-8px_rgba(97,32,47,0.6)]"
                      : "border-[#ece6ee] bg-white text-[#5a5460] hover:border-[#d9c3ca] hover:text-[#61202f]"
                  }`}
                >
                  <s.icon size={15} />
                  <span>
                    <span className="block text-[13px] font-semibold leading-tight">{s.label}</span>
                    <span className={`block text-[10.5px] leading-tight ${active ? "text-white/70" : "text-[#8b8296]"}`}>
                      {s.hint}
                    </span>
                  </span>
                </button>
              );
            })}
            <button
              onClick={() => setRunKey((k) => k + 1)}
              className="flex items-center gap-1.5 rounded-xl border border-[#ece6ee] bg-white px-3 py-2 text-[12.5px] font-semibold text-[#5a5460] transition-colors hover:border-[#d9c3ca] hover:text-[#61202f]"
            >
              <RotateCcw size={13} className={finished ? "text-[#61202f]" : ""} />
              Replay
            </button>
          </div>

          <div className="grid gap-5 lg:grid-cols-[minmax(0,380px)_minmax(0,1fr)]">
            <ChatPanel messages={messages} />
            <div ref={desktopRef} className="relative">
              <Desktop
                scenario={scenario}
                reg={reg}
                glowOn={glowOn}
                snapOn={snapOn}
                scanKey={scanKey}
                ocrOn={ocrOn}
                typedSlack={typedSlack}
                typingTarget={typingTarget}
                sent={sent}
                pressedId={pressedId}
                toast={toast}
                pointer={pointer}
                ripples={ripples}
                toggleNightShift={toggleNightShift}
                toggleTrueTone={toggleTrueTone}
                toggleHotCorners={toggleHotCorners}
                autoBrightness={autoBrightness}
                sliderLevel={sliderLevel}
                sliderDragging={sliderDragging}
              />
            </div>
          </div>

          <p className="mt-5 text-center text-[12.5px] text-[#8b8296]">
            This walkthrough uses Macbeth's current MCP tool names and illustrates its glow,
            pointer, and capture sequence.{" "}
            <a
              href="https://github.com/wende/macbeth#quickstart"
              target="_blank"
              rel="noreferrer"
              className="font-medium text-[#61202f] underline decoration-[#d9c3ca] underline-offset-2 hover:decoration-[#61202f]"
            >
              Try the Finder smoke test
            </a>
          </p>
        </Reveal>
      </div>
    </section>
  );
}
