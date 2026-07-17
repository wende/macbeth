import { useEffect, useRef } from "react";
import { Check, Loader2, Wrench } from "lucide-react";

export type ChatMsg =
  | { id: number; kind: "user"; text: string }
  | { id: number; kind: "assistant"; text: string }
  | { id: number; kind: "tool"; name: string; args: string; status: "running" | "done"; result?: string }
  | { id: number; kind: "shot" };

export type ChatMsgInput =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "tool"; name: string; args: string; status: "running" | "done"; result?: string }
  | { kind: "shot" };

function ShotCard() {
  return (
    <div className="sim-msg ml-6 w-[190px] overflow-hidden rounded-lg border border-white/15 bg-[#17131d]">
      <div className="flex items-center gap-1 border-b border-white/10 bg-[#1f1a26] px-2 py-1.5">
        <span className="h-[6px] w-[6px] rounded-full bg-[#ff5f57]" />
        <span className="h-[6px] w-[6px] rounded-full bg-[#febc2e]" />
        <span className="h-[6px] w-[6px] rounded-full bg-[#28c840]" />
        <span className="ml-1.5 text-[9px] text-[#8d8499]">Notes</span>
      </div>
      <div className="space-y-1.5 px-3 py-2.5">
        <div className="h-[5px] w-3/4 rounded-full bg-[#4a4257]" />
        <div className="h-[5px] w-full rounded-full bg-[#3a3344]" />
        <div className="h-[5px] w-5/6 rounded-full bg-[#3a3344]" />
        <div className="h-[5px] w-2/3 rounded-full bg-[#3a3344]" />
      </div>
      <div className="border-t border-white/10 px-2.5 py-1.5 font-mono text-[9.5px] text-[#8d8499]">
        notes-window.png · 1240×980
      </div>
    </div>
  );
}

export default function ChatPanel({ messages }: { messages: ChatMsg[] }) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  }, [messages.length]);

  return (
    <div className="flex h-[440px] flex-col overflow-hidden rounded-2xl border border-[#241e2b] bg-[#0f0d12] shadow-[0_24px_60px_-20px_rgba(15,13,18,0.55)] lg:h-[560px]">
      {/* title bar */}
      <div className="flex items-center gap-2 border-b border-white/10 px-4 py-3">
        <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#ff5f57]" />
        <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#febc2e]" />
        <span className="h-[10px] w-[10px] shrink-0 grow-0 rounded-full bg-[#28c840]" />
        <span className="ml-2 font-mono text-[11.5px] text-[#8d8499]">claude — Claude Code</span>
        <span className="ml-auto flex items-center gap-1.5 rounded-full border border-white/10 bg-white/5 px-2 py-0.5 font-mono text-[10px] text-[#c9a0b5]">
          <span className="h-1.5 w-1.5 rounded-full bg-[#8b3342]" />
          macbeth MCP
        </span>
      </div>

      {/* messages */}
      <div ref={scrollRef} className="scrollbar-hide flex-1 space-y-4 overflow-y-auto px-4 py-4">
        {messages.map((m) => {
          if (m.kind === "user") {
            return (
              <div key={m.id} className="sim-msg flex gap-2.5">
                <span className="mt-0.5 font-mono text-[13px] font-semibold text-[#c47a88]">&gt;</span>
                <p className="font-mono text-[13px] leading-[1.55] text-[#f4f1f8]">{m.text}</p>
              </div>
            );
          }
          if (m.kind === "assistant") {
            return (
              <div key={m.id} className="sim-msg flex gap-2.5">
                <span className="mt-[3px] h-2 w-2 shrink-0 rounded-full bg-[#8b3342]" />
                <p className="text-[13px] leading-[1.6] text-[#cfc7d8]">{m.text}</p>
              </div>
            );
          }
          if (m.kind === "shot") {
            return <ShotCard key={m.id} />;
          }
          return (
            <div key={m.id} className="sim-msg ml-6 rounded-lg border border-white/10 bg-white/[0.04] px-3 py-2.5">
              <div className="flex items-center gap-2">
                <Wrench size={12} className="shrink-0 text-[#c47a88]" />
                <code className="font-mono text-[12px] font-medium text-[#e8b7c3]">
                  {m.name}
                  <span className="text-[#8d8499]">({m.args})</span>
                </code>
                <span className="ml-auto">
                  {m.status === "running" ? (
                    <Loader2 size={13} className="animate-spin text-[#8d8499]" />
                  ) : (
                    <Check size={13} className="text-[#a8d8a0]" />
                  )}
                </span>
              </div>
              {m.status === "done" && m.result && (
                <div className="mt-1.5 border-t border-white/5 pt-1.5 font-mono text-[11px] text-[#8d8499]">
                  → {m.result}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
