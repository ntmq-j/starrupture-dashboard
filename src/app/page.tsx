import { redirect } from "next/navigation";
import { isAuthenticated } from "@/lib/auth";

export const dynamic = "force-dynamic";

export default async function Home() {
  redirect((await isAuthenticated()) ? "/dashboard" : "/login");
}
