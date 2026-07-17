export default function Logo({ className = "", showWordmark = true }: { className?: string; showWordmark?: boolean }) {
  return (
    <svg
      className={className}
      xmlns="http://www.w3.org/2000/svg"
      width={showWordmark ? 400 : 100}
      height={128}
      viewBox={showWordmark ? "0 0 400 128" : "0 0 110 128"}
      fill="none"
      role="img"
      aria-label="macbeth"
    >
      <title>Macbeth</title>
      <defs>
        <filter id="shadow" x="-30%" y="-30%" width="170%" height="180%">
          <feDropShadow dx="0" dy="4" stdDeviation="3" floodColor="#090612" floodOpacity=".35" />
        </filter>
        <linearGradient id="cursor" x1="28" y1="18" x2="87" y2="104" gradientUnits="userSpaceOnUse">
          <stop stopColor="#8B3342" />
          <stop offset=".5" stopColor="#61202F" />
          <stop offset="1" stopColor="#32111A" />
        </linearGradient>
      </defs>
      <path
        d="M18 13.5v82.2c0 4.1 5 6.1 7.8 3.1L44 79.4l13.1 28.1c1.1 2.4 4 3.4 6.4 2.3l12.2-5.7c2.4-1.1 3.4-4 2.3-6.4L65.2 70.2h25.5c4.2 0 6.2-5.3 2.9-7.9L25.4 9.9c-3-2.3-7.4-.2-7.4 3.6Z"
        fill="url(#cursor)"
        stroke="#F8F7FA"
        strokeWidth="6"
        strokeLinejoin="round"
        filter="url(#shadow)"
      />
      <path
        d="m30 28 43 33H54.9l15.8 34-7.1 3.3-16-34.4-17.6 19V28Z"
        fill="#F4F1F8"
        fillOpacity=".09"
      />
      {showWordmark && (
        <text
          x="140"
          y="84"
          fill="#61202F"
          stroke="#F8F7FA"
          strokeWidth="4"
          paintOrder="stroke fill"
          strokeLinejoin="round"
          filter="url(#shadow)"
          fontFamily="-apple-system, BlinkMacSystemFont, SF Pro Display, Helvetica Neue, Arial, sans-serif"
          fontSize="67"
          fontWeight="700"
          letterSpacing="-3.5"
        >
          macbeth
        </text>
      )}
    </svg>
  );
}
