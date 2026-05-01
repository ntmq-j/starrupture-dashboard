import { NextRequest, NextResponse } from "next/server";
import { apiError } from "@/lib/api";
import { requireAuthResponse } from "@/lib/auth";
import { restoreSaveSession } from "@/lib/aws";

export async function POST(request: NextRequest) {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  try {
    const body = (await request.json().catch(() => null)) as { fileName?: string } | null;
    if (!body?.fileName) {
      return apiError(new Error("fileName is required."), 400);
    }

    return NextResponse.json(await restoreSaveSession(body.fileName));
  } catch (error) {
    return apiError(error);
  }
}
