import { NextResponse } from "next/server";
import { apiError } from "@/lib/api";
import { requireAuthResponse } from "@/lib/auth";
import { startInstance } from "@/lib/aws";

export async function POST() {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  try {
    await startInstance();
    return NextResponse.json({ ok: true });
  } catch (error) {
    return apiError(error);
  }
}
