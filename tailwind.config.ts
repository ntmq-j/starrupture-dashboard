import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        panel: "#111827",
        line: "#263244",
        ember: "#f97316",
        cyan: "#22d3ee",
      },
      boxShadow: {
        glow: "0 0 34px rgba(34, 211, 238, 0.12)",
      },
    },
  },
  plugins: [],
};

export default config;
