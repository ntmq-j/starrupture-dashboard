import { NextResponse } from "next/server";
import { apiError } from "@/lib/api";
import { getInstanceStatus } from "@/lib/aws";
import { requireAuthResponse } from "@/lib/auth";

export async function GET() {
  const unauthorized = await requireAuthResponse();
  if (unauthorized) {
    return unauthorized;
  }

  try {
    return NextResponse.json(await getInstanceStatus());
  } catch (error) {
    return apiError(error);
  }
}
