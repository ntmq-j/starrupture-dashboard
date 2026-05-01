import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "StarRupture Dashboard",
  description: "Secure EC2 control dashboard for StarRupture Dedicated Server.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
