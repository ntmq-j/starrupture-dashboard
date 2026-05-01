import { NextRequest, NextResponse } from "next/server";

const SESSION_COOKIE = "starrupture_session";

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const isLoginPage = pathname === "/login";
  const isProtectedPage = pathname === "/dashboard";
  const isProtectedApi =
    pathname.startsWith("/api/") && !pathname.startsWith("/api/auth/login");

  if (!isProtectedPage && !isProtectedApi && !isLoginPage) {
    return NextResponse.next();
  }

  const isAuthed = await hasValidSession(request);

  if (isLoginPage && isAuthed) {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  if ((isProtectedPage || isProtectedApi) && !isAuthed) {
    if (isProtectedApi) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    return NextResponse.redirect(new URL("/login", request.url));
  }

  return NextResponse.next();
}

async function hasValidSession(request: NextRequest) {
  const password = process.env.DASHBOARD_PASSWORD;
  const value = request.cookies.get(SESSION_COOKIE)?.value;

  if (!password || !value) {
    return false;
  }

  const expected = await sessionToken(password);
  return value === expected;
}

async function sessionToken(password: string) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(password),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode("starrupture-dashboard-session-v1"),
  );

  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export const config = {
  matcher: ["/login", "/dashboard", "/api/:path*"],
};
