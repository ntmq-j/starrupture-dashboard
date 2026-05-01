import { NextResponse } from "next/server";
import { apiError } from "@/lib/api";
import { requireAuthResponse } from "@/lib/auth";
import { getLogEvents } from "@/lib/aws";

export async function GET() {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  try {
    return NextResponse.json(await getLogEvents());
  } catch (error) {
    return apiError(error);
  }
}
