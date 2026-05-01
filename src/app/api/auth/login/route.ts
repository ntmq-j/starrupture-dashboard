import { NextResponse } from "next/server";
import { createSessionCookie, verifyPassword } from "@/lib/auth";
import { apiError } from "@/lib/api";

export async function POST(request: Request) {
  try {
    const body = (await request.json()) as { password?: string };

    if (!body.password || !verifyPassword(body.password)) {
      return NextResponse.json({ error: "Invalid password." }, { status: 401 });
    }

    const response = NextResponse.json({ ok: true });
    createSessionCookie(response);
    return response;
  } catch (error) {
    return apiError(error);
  }
}
