import { NextResponse } from "next/server";
import { clearSessionCookie, requireAuthResponse } from "@/lib/auth";

export async function POST() {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  const response = NextResponse.json({ ok: true });
  clearSessionCookie(response);
  return response;
}
