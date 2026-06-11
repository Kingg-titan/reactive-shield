import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = {
  title: "ReactiveShield Console",
  description: "ReactiveShield IL insurance hook demo console"
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

