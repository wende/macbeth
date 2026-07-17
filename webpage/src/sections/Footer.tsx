import Logo from "../components/Logo";

const COLS = [
  {
    title: "Explore",
    links: [
      { label: "Features", href: "#features" },
      { label: "Live demo", href: "#demo" },
    ],
  },
  {
    title: "Learn",
    links: [
      { label: "Permissions", href: "#permissions" },
      { label: "FAQ", href: "#faq" },
      { label: "README", href: "https://github.com/wende/macbeth#readme" },
      { label: "Releases", href: "https://github.com/wende/macbeth/releases" },
    ],
  },
  {
    title: "Project",
    links: [
      { label: "GitHub", href: "https://github.com/wende/macbeth" },
      { label: "npm", href: "https://www.npmjs.com/package/macbeth" },
      { label: "Issues", href: "https://github.com/wende/macbeth/issues" },
      { label: "MIT License", href: "https://github.com/wende/macbeth/blob/main/LICENSE" },
    ],
  },
];

export default function Footer() {
  return (
    <footer className="border-t border-[#ece6ee] bg-[#fbfafc]">
      <div className="mx-auto max-w-[1120px] px-6 py-14">
        <div className="grid gap-10 md:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]">
          <div>
            <Logo showWordmark={false} className="mb-3 h-[30px] w-auto" />
            <p className="max-w-[30ch] text-[13px] leading-[1.6] text-[#5a5460]">
              Playwright for macOS — automate native and Electron apps through the Accessibility API.
            </p>
          </div>
          <div className="grid grid-cols-2 gap-8 sm:grid-cols-3">
            {COLS.map((c) => (
              <div key={c.title}>
                <h4 className="mb-3 text-[11.5px] font-bold uppercase tracking-[0.12em] text-[#61202f]">
                  {c.title}
                </h4>
                <ul className="space-y-2">
                  {c.links.map((l) => (
                    <li key={l.label}>
                      <a
                        href={l.href}
                        target={l.href.startsWith("http") ? "_blank" : undefined}
                        rel={l.href.startsWith("http") ? "noreferrer" : undefined}
                        className="text-[13px] text-[#5a5460] transition-colors hover:text-[#61202f]"
                      >
                        {l.label}
                      </a>
                    </li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </div>
        <div className="mt-12 flex flex-col items-center justify-between gap-3 border-t border-[#ece6ee] pt-6 sm:flex-row">
          <p className="text-[12px] text-[#8b8296]">macbeth — MIT licensed. Built with Swift 6 and TypeScript.</p>
          <p className="font-mono text-[11.5px] text-[#8b8296]">“Is this a locator which I see before me?”</p>
        </div>
      </div>
    </footer>
  );
}
