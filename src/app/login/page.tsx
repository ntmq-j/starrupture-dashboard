import { redirect } from "next/navigation";
import LoginForm from "@/components/LoginForm";
import { isAuthenticated } from "@/lib/auth";

export const dynamic = "force-dynamic";

export default async function LoginPage() {
  if (await isAuthenticated()) {
    redirect("/dashboard");
  }

  return <LoginForm />;
}
