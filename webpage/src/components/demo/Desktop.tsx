import type { ReactNode } from "react";

export type ScenarioId = "settings" | "slack" | "shot";
export type RegFn = (id: string) => (el: HTMLElement | null) => void;

export interface DesktopProps {
  scenario: ScenarioId;
  reg: RegFn;
  glowOn: boolean;
  snapOn: boolean;
  scanKey: number;
  ocrOn: boolean;
  typedSlack: string;
  typingTarget: string | null;
  sent: string[];
  pressedId: string | null;
  toast: string | null;
  pointer: { x: number; y: number; visible: boolean };
  ripples: { id: number; x: number; y: number }[];
  /* settings scenario */
  toggleNightShift: boolean;
  toggleTrueTone: boolean;
  toggleHotCorners: boolean;
  autoBrightness: boolean;
  sliderLevel: number;
  sliderDragging: boolean;
}

const APP_NAME: Record<ScenarioId, string> = {
  settings: "System Settings",
  slack: "Slack",
  shot: "Notes",
};

function TrafficLights({ title, badge }: { title: string; badge?: string }) {
  return (
    <div className="flex items-center gap-2 border-b border-[#e5e5ea] bg-[#f5f5f7] px-3.5 py-2.5">
      <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#ff5f57]" />
      <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#febc2e]" />
      <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#28c840]" />
      <span className="ml-2 truncate text-[11.5px] font-medium text-[#1d1d1f]">{title}</span>
      {badge && (
        <span className="ml-auto shrink-0 rounded-md bg-[#f8eef0] px-1.5 py-0.5 font-mono text-[9px] font-medium text-[#8b3342]">
          {badge}
        </span>
      )}
    </div>
  );
}

/* ---------- System Settings (Displays) ---------- */
/* Visual model: real macOS Settings light form group (burgundy replaces system blue) */

/**
 * macOS System Settings toggle (light mode).
 * Pill track (wide capsule, not a circle) with a large circular thumb.
 * ON uses brand burgundy instead of system blue.
 */
function Switch({ on }: { on: boolean }) {
  return (
    <span
      className={`relative inline-block h-[16px] w-[30px] shrink-0 rounded-full transition-colors duration-200 ease-out ${
        on ? "bg-[#0a84ff]" : "bg-[#d8d8dc]"
      }`}
      aria-hidden
    >
      <span
        className={`absolute top-[2px] block h-[12px] w-[16px] rounded-full bg-white transition-[left] duration-200 ease-out ${
          on ? "left-[12px]" : "left-[2px]"
        }`}
        style={{
          boxShadow:
            "0 1px 2px rgba(0,0,0,0.16), 0 1px 4px rgba(0,0,0,0.1), 0 0 0 0.5px rgba(0,0,0,0.04)",
        }}
      />
    </span>
  );
}


function SettingsRow({
  id,
  label,
  hint,
  on,
  pressed,
  reg,
  last,
}: {
  id: string;
  label: string;
  hint?: string;
  on: boolean;
  pressed: boolean;
  reg: RegFn;
  last?: boolean;
}) {
  return (
    <button
      ref={reg(id)}
      className={`relative flex w-full items-center gap-3 px-3.5 py-[10px] text-left transition-colors ${
        pressed ? "bg-[#efe6ea]" : "hover:bg-black/[0.025]"
      }`}
    >
      {!last && (
        <span
          className="pointer-events-none absolute inset-x-3.5 bottom-0 h-px bg-black/[0.08]"
          aria-hidden
        />
      )}
      <span className="min-w-0 flex-1">
        <span className="block text-[11px] font-normal leading-[1.25] text-[#1d1d1f]">{label}</span>
        {hint && (
          <span className="mt-[2px] block text-[10px] leading-[1.35] text-[#8e8e93]">{hint}</span>
        )}
      </span>
      <span ref={reg(`${id}-switch`)} className="inline-flex shrink-0">
        <Switch on={on} />
      </span>
    </button>
  );
}

function SunIcon({ dim }: { dim?: boolean }) {
  /* dim = low-brightness glyph; full = high-brightness */
  const center = dim ? 2.6 : 3.2;
  const orbitR = dim ? 5.6 : 6.6;
  const dotR = dim ? 1.0 : 1.2;
  return (
    <svg
      width={dim ? 14 : 18}
      height={dim ? 14 : 18}
      viewBox="0 0 16 16"
      fill="none"
      className="shrink-0 text-[#6e6e73]"
      aria-hidden
    >
      <circle cx="8" cy="8" r={center} fill="currentColor" />
      {[0, 45, 90, 135, 180, 225, 270, 315].map((deg) => {
        const rad = (deg * Math.PI) / 180;
        return (
          <circle
            key={deg}
            cx={8 + Math.cos(rad) * orbitR}
            cy={8 + Math.sin(rad) * orbitR}
            r={dotR}
            fill="currentColor"
          />
        );
      })}
    </svg>
  );
}

const SIDEBAR_ITEMS: { name: string; tint: string }[] = [
  { name: "Wi-Fi", tint: "#007aff" },
  { name: "Bluetooth", tint: "#0a84ff" },
  { name: "Displays", tint: "#61202f" },
  { name: "Wallpaper", tint: "#af52de" },
  { name: "Sound", tint: "#ff9f0a" },
];

function SettingsWindow(p: DesktopProps) {
  return (
    <>
      <TrafficLights title="System Settings" badge="macbeth connected" />
      <div className="flex min-h-[200px] bg-white sm:min-h-[230px]">
        {/* sidebar */}
        <div className="hidden w-[128px] shrink-0 flex-col gap-0.5 border-r border-[#e8e8ed] bg-[#f7f7f8] px-2 py-2.5 sm:flex">
          {SIDEBAR_ITEMS.map((s) => {
            const active = s.name === "Displays";
            return (
              <span
                key={s.name}
                className={`flex items-center gap-1.5 rounded-[6px] px-1.5 py-[5px] text-[11px] ${
                  active ? "bg-[#61202f] font-medium text-white" : "text-[#3a3a3c]"
                }`}
              >
                <span
                  className="flex h-[14px] w-[14px] shrink-0 items-center justify-center rounded-[3.5px]"
                  style={{ background: active ? "rgba(255,255,255,0.22)" : s.tint }}
                  aria-hidden
                >
                  <span className="h-[5px] w-[5px] rounded-[1px] bg-white/95" />
                </span>
                {s.name}
              </span>
            );
          })}
        </div>

        {/* panel — white page, gray form group (as in real System Settings) */}
        <div
          className="min-w-0 flex-1 bg-white px-4 py-3.5"
          style={{
            fontFamily:
              '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
          }}
        >
          <h4 className="mb-2.5 text-[13px] font-semibold tracking-[-0.015em] text-[#1d1d1f]">
            Displays
          </h4>

          {/* form group card */}
          <div className="overflow-hidden rounded-[12px] bg-[#f5f5f7]">
            {/* Brightness — label left, slider cluster right */}
            <div className="relative flex items-center gap-3 px-3.5 py-[11px]">
              <span
                className="pointer-events-none absolute inset-x-3.5 bottom-0 h-px bg-black/[0.08]"
                aria-hidden
              />
              <span className="shrink-0 text-[11px] leading-none text-[#1d1d1f]">Brightness</span>
              <div className="flex min-w-0 flex-1 items-center justify-end gap-[7px]">
                <SunIcon dim />
                <div className="relative flex h-[18px] w-full max-w-[168px] items-center sm:max-w-[200px]">
                  <div className="relative h-[6px] w-full rounded-full bg-[#d1d1d6]">
                    <div
                      className={`absolute left-0 top-0 h-full rounded-full bg-[#0a84ff] ${
                        p.sliderDragging ? "" : "transition-[width] duration-150"
                      }`}
                      style={{ width: `${p.sliderLevel * 100}%` }}
                    />
                  </div>
                  <span
                    ref={p.reg("slider")}
                    className={`absolute top-1/2 block h-[14px] w-[22px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-white shadow-[0_0.5px_1px_rgba(0,0,0,0.1),0_1px_3px_rgba(0,0,0,0.2),0_0_0_0.5px_rgba(0,0,0,0.04)] ${
                      p.sliderDragging
                        ? "scale-110 ring-2 ring-[#8b3342]/35"
                        : "transition-[left] duration-150"
                    }`}
                    style={{ left: `${p.sliderLevel * 100}%` }}
                  />
                </div>
                <SunIcon />
              </div>
            </div>

            {/* Automatically adjust brightness */}
            <button
              ref={p.reg("auto-brightness")}
              className={`relative flex w-full items-start gap-3 px-3.5 py-[10px] text-left transition-colors ${
                p.pressedId === "auto-brightness" ? "bg-[#efe6ea]" : "hover:bg-black/[0.025]"
              }`}
            >
              <span
                className="pointer-events-none absolute inset-x-3.5 bottom-0 h-px bg-black/[0.08]"
                aria-hidden
              />
              <span className="min-w-0 flex-1">
                <span className="block text-[11px] font-normal leading-[1.25] text-[#1d1d1f]">
                  Automatically adjust brightness
                </span>
              </span>
              <span ref={p.reg("auto-brightness-switch")} className="mt-0.5 shrink-0">
                <Switch on={p.autoBrightness} />
              </span>
            </button>

            <SettingsRow
              id="truetone"
              label="True Tone"
              hint="Automatically adapt display to make colors appear consistent in different ambient lighting conditions."
              on={p.toggleTrueTone}
              pressed={p.pressedId === "truetone"}
              reg={p.reg}
            />
            <SettingsRow
              id="nightshift"
              label="Night Shift"
              hint="Sunset to sunrise"
              on={p.toggleNightShift}
              pressed={p.pressedId === "nightshift"}
              reg={p.reg}
            />
            <SettingsRow
              id="hotcorners"
              label="Hot Corners"
              hint="Quick actions in screen corners"
              on={p.toggleHotCorners}
              pressed={p.pressedId === "hotcorners"}
              reg={p.reg}
              last
            />
          </div>

          {p.toast && (
            <div className="sim-toast absolute right-3 top-12 rounded-lg bg-[#0f0d12] px-2.5 py-1.5 font-mono text-[10px] text-[#f4f1f8] shadow-lg">
              {p.toast}
            </div>
          )}
        </div>
      </div>
    </>
  );
}

/* ---------- Slack ---------- */

function SlackWindow(p: DesktopProps) {
  const history = [
    { who: "anna", color: "#8b3342", text: "standup moved to 10:30 today", when: "09:31" },
    { who: "kris", color: "#3b6ea5", text: "build is green on main again", when: "09:34" },
  ];
  return (
    <>
      <TrafficLights title="Slack — #engineering" badge="Electron · web content ready" />
      <div className="flex min-h-[200px] sm:min-h-[230px]">
        <div className="hidden w-[108px] shrink-0 flex-col gap-0.5 border-r border-[#ece6ee] bg-[#3f1f2b] px-2 py-2.5 sm:flex">
          {["general", "engineering", "random"].map((c) => (
            <span
              key={c}
              className={`rounded px-1.5 py-1 text-[10.5px] ${
                c === "engineering" ? "bg-white/15 font-semibold text-white" : "text-white/55"
              }`}
            >
              # {c}
            </span>
          ))}
          <span className="mt-auto px-1.5 text-[9px] text-white/40">macbeth workspace</span>
        </div>
        <div className="flex min-w-0 flex-1 flex-col">
          <div className="flex-1 space-y-2.5 overflow-hidden px-3.5 py-3">
            {history.map((m) => (
              <div key={m.who} className="flex gap-2">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md text-[10px] font-bold text-white" style={{ background: m.color }}>
                  {m.who[0]}
                </span>
                <div className="min-w-0">
                  <span className="text-[11px] font-bold text-[#1a1520]">{m.who}</span>
                  <span className="ml-1.5 text-[9.5px] text-[#8b8296]">{m.when}</span>
                  <p className="truncate text-[11.5px] text-[#3d3644]">{m.text}</p>
                </div>
              </div>
            ))}
            {p.sent.map((text, i) => (
              <div key={i} className="sim-msg flex gap-2">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-[#61202f] text-[10px] font-bold text-white">c</span>
                <div className="min-w-0">
                  <span className="text-[11px] font-bold text-[#1a1520]">claude</span>
                  <span className="ml-1.5 rounded bg-[#f8eef0] px-1 py-px text-[8.5px] font-bold uppercase text-[#8b3342]">app</span>
                  <span className="ml-1.5 text-[9.5px] text-[#8b8296]">09:41</span>
                  <p className="text-[11.5px] text-[#3d3644]">{text}</p>
                </div>
              </div>
            ))}
          </div>
          <div className="flex items-center gap-2 border-t border-[#ece6ee] px-3 py-2.5">
            <div
              ref={p.reg("slack-input")}
              className="min-h-[30px] flex-1 rounded-lg border border-[#d8d2dc] bg-white px-2.5 py-1.5 text-[11.5px] text-[#3d3644]"
            >
              {p.typedSlack ? (
                <>
                  {p.typedSlack}
                  {p.typingTarget === "slack-input" && <span className="sim-caret" />}
                </>
              ) : (
                <span className="text-[#b6afc0]">
                  Message #engineering
                  {p.typingTarget === "slack-input" && <span className="sim-caret" />}
                </span>
              )}
            </div>
            <button
              ref={p.reg("send")}
              className={`rounded-lg bg-[#61202f] px-3 py-1.5 text-[11px] font-semibold text-white transition-transform duration-150 ${
                p.pressedId === "send" ? "scale-90" : ""
              }`}
            >
              Send
            </button>
          </div>
        </div>
      </div>
    </>
  );
}

/* ---------- Notes ---------- */

const NOTE_LINES = [
  "macbeth release checklist",
  "notarize daemon binary",
  "prepare npm release",
  "update bundled app skills",
];

function NotesWindow(p: DesktopProps) {
  return (
    <>
      <TrafficLights title="Notes" badge="macbeth connected" />
      <div className="flex min-h-[200px] sm:min-h-[230px]">
        <div className="hidden w-[110px] shrink-0 flex-col gap-1 border-r border-[#ece6ee] bg-[#fbfafc] px-2 py-2.5 sm:flex">
          {["release checklist", "reading list", "gift ideas"].map((n, i) => (
            <span
              key={n}
              className={`truncate rounded-md px-1.5 py-1 text-[10px] ${
                i === 0 ? "bg-[#f8eef0] font-semibold text-[#61202f]" : "text-[#8b8296]"
              }`}
            >
              {n}
            </span>
          ))}
        </div>
        <div ref={p.reg("note-body")} className="relative flex-1 px-4 py-3.5">
          {NOTE_LINES.map((line, i) => (
            <p
              key={line}
              className={`rounded px-1.5 py-1 text-[12.5px] transition-colors duration-500 ${
                i === 0 ? "mb-1 text-[14px] font-bold text-[#1a1520]" : "text-[#3d3644]"
              } ${p.ocrOn ? "bg-[#8b3342]/10 outline outline-1 outline-[#8b3342]/40" : ""}`}
            >
              {i > 0 && <span className="mr-1.5 text-[#8b3342]">•</span>}
              {line}
            </p>
          ))}
          {p.ocrOn && (
            <div className="sim-msg absolute bottom-2.5 right-3 rounded-md bg-[#0f0d12] px-2 py-1 font-mono text-[9.5px] text-[#f4f1f8]">
              4 text blocks recognized
            </div>
          )}
        </div>
      </div>
    </>
  );
}

/* ---------- desktop shell ---------- */

export default function Desktop(p: DesktopProps) {
  const dock = [
    { id: "finder", label: "F", bg: "#3b6ea5" },
    { id: "settings", label: "{}", bg: "#e9e4ec", fg: "#5a5460" },
    { id: "slack", label: "S", bg: "#4a154b" },
    { id: "shot", label: "N", bg: "#f6d95f", fg: "#6b5510" },
    { id: "safari", label: "≈", bg: "#e8f1fb", fg: "#1d6fd1" },
  ];

  let content: ReactNode;
  if (p.scenario === "settings") content = <SettingsWindow {...p} />;
  else if (p.scenario === "slack") content = <SlackWindow {...p} />;
  else content = <NotesWindow {...p} />;

  return (
    <div
      className="relative flex h-[440px] flex-col overflow-hidden rounded-2xl border border-[#e4dce7] shadow-[0_24px_60px_-20px_rgba(97,32,47,0.3)] lg:h-[560px]"
      style={{ background: "linear-gradient(160deg, #f2ebf4 0%, #e9dfec 45%, #ddcfe4 100%)" }}
    >
      {/* menu bar */}
      <div className="flex items-center gap-3 bg-white/60 px-4 py-1.5 backdrop-blur-sm">
        <span className="h-2 w-2 shrink-0 rounded-full bg-[#61202f]" />
        <span className="text-[11px] font-bold text-[#3d3644]">{APP_NAME[p.scenario]}</span>
        <span className="hidden text-[11px] text-[#8b8296] sm:inline">File</span>
        <span className="hidden text-[11px] text-[#8b8296] sm:inline">Edit</span>
        <span className="ml-auto font-mono text-[10px] text-[#8b8296]">Tue 09:41</span>
      </div>

      {/* window */}
      <div className="flex flex-1 items-center justify-center px-4 py-5 sm:px-8">
        <div className="w-full max-w-[540px]">
          <div
            ref={p.reg("window")}
            className={`relative overflow-hidden rounded-[14px] border border-[#d8d2dc] bg-white shadow-[0_30px_70px_-24px_rgba(26,21,32,0.4)] transition-shadow duration-500 ${
              p.glowOn ? "mock-window-glow" : ""
            } ${p.snapOn ? "sim-snap" : ""}`}
          >
            {content}
            {p.scanKey > 0 && <div key={p.scanKey} className="sim-scanline" />}
          </div>
        </div>
      </div>

      {/* dock */}
      <div className="flex justify-center pb-3">
        <div className="flex items-end gap-2 rounded-2xl border border-white/50 bg-white/40 px-3 py-2 backdrop-blur-md">
          {dock.map((d) => (
            <div key={d.id} className="flex flex-col items-center gap-1">
              <span
                className={`flex h-9 w-9 items-center justify-center rounded-[10px] text-[15px] font-bold shadow-sm transition-transform duration-300 ${
                  d.id === p.scenario ? "-translate-y-1" : ""
                }`}
                style={{ background: d.bg, color: d.fg ?? "#fff" }}
              >
                {d.label}
              </span>
              <span className={`h-1 w-1 rounded-full ${d.id === p.scenario ? "bg-[#61202f]" : "bg-transparent"}`} />
            </div>
          ))}
        </div>
      </div>

      {/* synthetic pointer */}
      <div
        className="sim-pointer"
        style={{ left: p.pointer.x, top: p.pointer.y, opacity: p.pointer.visible ? 1 : 0 }}
      >
        <svg width="19" height="19" viewBox="0 0 24 24" fill="none" style={{ filter: "drop-shadow(0 1px 3px rgba(50,17,26,0.5))" }}>
          <path
            d="M4.5 2.8v16.9c0 .85 1.03 1.26 1.6.64l3.79-4.04 2.72 5.84c.23.5.83.7 1.33.47l2.53-1.18c.5-.23.7-.83.47-1.33l-2.66-5.71h5.3c.86 0 1.29-1.1.6-1.63L5.62 2.66c-.62-.48-1.12-.06-1.12.14Z"
            fill="#8B3342"
            stroke="#fff"
            strokeWidth="1.6"
            strokeLinejoin="round"
          />
        </svg>
      </div>

      {/* click ripples — same coordinates as the pointer */}
      {p.ripples.map((r) => (
        <span key={r.id} className="sim-ripple" style={{ left: r.x, top: r.y }} />
      ))}
    </div>
  );
}
