import { NextResponse } from "next/server";
import { apiError } from "@/lib/api";
import { requireAuthResponse } from "@/lib/auth";
import { getInstanceMetrics } from "@/lib/aws";

export async function GET() {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  try {
    return NextResponse.json(await getInstanceMetrics());
  } catch (error) {
    return apiError(error);
  }
}
