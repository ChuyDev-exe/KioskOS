/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./index.html", "./script.js", "./style.css"],
  theme: {
    extend: {
      colors: {
        bg: "#0b0f14",
        surface: "#121821",
        raised: "#182130",
        line: "#233041",
        text: "#e6edf3",
        muted: "#8b98a5",
        accent: "#3b82f6",
        ok: "#22c55e",
        warn: "#f59e0b",
        danger: "#ef4444",
      },
      borderRadius: {
        DEFAULT: "6px",
        lg: "10px",
      },
      fontFamily: {
        sans: [
          "system-ui",
          "-apple-system",
          "Segoe UI",
          "Roboto",
          "Helvetica Neue",
          "Arial",
          "sans-serif",
        ],
      },
      fontSize: {
        xs: ["12px", "16px"],
        sm: ["13px", "18px"],
        base: ["15px", "22px"],
        lg: ["18px", "26px"],
        xl: ["24px", "32px"],
      },
      spacing: {
        1: "4px",
        2: "8px",
        3: "12px",
        4: "16px",
        5: "20px",
        6: "24px",
        8: "32px",
        10: "40px",
      },
    },
  },
  plugins: [],
};
