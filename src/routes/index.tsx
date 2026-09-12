import { createFileRoute } from "@tanstack/react-router";
import { IdeApp } from "@/components/ide/app-shell";

export const Route = createFileRoute("/")({ component: Home });

function Home() {
  return <IdeApp />;
}
