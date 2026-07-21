import { useEffect, useState } from "react";
import { Github, Menu, X } from "lucide-react";
import Logo from "../components/Logo";

const LINKS = [
  { href: "#features", label: "Features" },
  { href: "#demo", label: "Walkthrough" },
  { href: "#faq", label: "FAQ" },
];

export default function Nav() {
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={`nav-blur fixed inset-x-0 top-0 z-50 border-b transition-all duration-300 ${
        scrolled ? "border-[#ece6ee] shadow-[0_4px_24px_-12px_rgba(97,32,47,0.15)]" : "border-transparent"
      }`}
    >
      <div className="mx-auto flex h-[64px] max-w-[1120px] items-center gap-6 px-6">
        <a href="#top" className="flex items-center gap-2.5">
          <Logo showWordmark={false} className="h-[26px] w-auto" />
          <span className="text-[17px] font-bold tracking-[-0.02em] text-[#61202f]">macbeth</span>
        </a>

        <nav className="ml-2 hidden items-center gap-1 lg:flex">
          {LINKS.map((l) => (
            <a
              key={l.href}
              href={l.href}
              className="rounded-lg px-3 py-1.5 text-[13.5px] font-medium text-[#5a5460] transition-colors hover:bg-[#f8eef0] hover:text-[#61202f]"
            >
              {l.label}
            </a>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2.5">
          <a
            href="https://github.com/wende/macbeth#quickstart"
            target="_blank"
            rel="noreferrer"
            className="hidden items-center gap-2 rounded-lg border border-[#ece6ee] bg-white px-3 py-1.5 font-mono text-[12px] text-[#1a1520] transition-colors hover:border-[#d9c3ca] hover:bg-[#fbfafc] sm:flex"
          >
            Agent quickstart
          </a>
          <a
            href="https://github.com/wende/macbeth"
            target="_blank"
            rel="noreferrer"
            className="flex items-center gap-2 rounded-lg bg-[#61202f] px-3.5 py-1.5 text-[13px] font-semibold text-white shadow-[0_6px_16px_-6px_rgba(97,32,47,0.5)] transition-all hover:bg-[#4d1926]"
          >
            <Github size={15} />
            <span className="hidden sm:inline">GitHub</span>
          </a>
          <button
            className="rounded-lg p-2 text-[#5a5460] hover:bg-[#f8eef0] lg:hidden"
            onClick={() => setOpen(!open)}
            aria-label="Toggle menu"
          >
            {open ? <X size={20} /> : <Menu size={20} />}
          </button>
        </div>
      </div>

      {open && (
        <nav className="border-t border-[#ece6ee] bg-white px-6 py-3 lg:hidden">
          {LINKS.map((l) => (
            <a
              key={l.href}
              href={l.href}
              onClick={() => setOpen(false)}
              className="block rounded-lg px-3 py-2.5 text-[14px] font-medium text-[#5a5460] hover:bg-[#f8eef0] hover:text-[#61202f]"
            >
              {l.label}
            </a>
          ))}
        </nav>
      )}
    </header>
  );
}
