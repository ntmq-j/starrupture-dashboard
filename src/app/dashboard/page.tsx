import Dashboard from "@/components/Dashboard";
import { isAuthenticated } from "@/lib/auth";
import { redirect } from "next/navigation";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  if (!(await isAuthenticated())) {
    redirect("/login");
  }

  return <Dashboard />;
}
