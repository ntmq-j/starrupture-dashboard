import { createHmac, timingSafeEqual } from "crypto";
import { cookies } from "next/headers";
import { NextResponse } from "next/server";

export const SESSION_COOKIE = "starrupture_session";

const SESSION_MAX_AGE_SECONDS = 60 * 60 * 24 * 7;

export function requireDashboardPassword() {
  const password = process.env.DASHBOARD_PASSWORD;
  if (!password) {
    throw new Error("DASHBOARD_PASSWORD is not configured.");
  }

  return password;
}

function sessionToken(password: string) {
  return createHmac("sha256", password)
    .update("starrupture-dashboard-session-v1")
    .digest("hex");
}

export function verifyPassword(candidate: string) {
  const password = requireDashboardPassword();
  return secureCompare(candidate, password);
}

export function createSessionCookie(response: NextResponse) {
  response.cookies.set({
    name: SESSION_COOKIE,
    value: sessionToken(requireDashboardPassword()),
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: SESSION_MAX_AGE_SECONDS,
  });
}

export function clearSessionCookie(response: NextResponse) {
  response.cookies.set({
    name: SESSION_COOKIE,
    value: "",
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 0,
  });
}

export async function isAuthenticated() {
  const value = (await cookies()).get(SESSION_COOKIE)?.value;
  return Boolean(value && secureCompare(value, sessionToken(requireDashboardPassword())));
}

export async function requireAuthResponse() {
  try {
    if (await isAuthenticated()) {
      return null;
    }
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Authentication unavailable." },
      { status: 500 },
    );
  }

  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}

function secureCompare(left: string, right: string) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);

  if (leftBuffer.length !== rightBuffer.length) {
    return false;
  }

  return timingSafeEqual(leftBuffer, rightBuffer);
}
