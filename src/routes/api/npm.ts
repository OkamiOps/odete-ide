import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/api/npm")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const name = new URL(request.url).searchParams.get("name")?.trim();
        if (!name) return Response.json({ error: "name" }, { status: 400 });
        const r = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/latest`);
        if (!r.ok) return Response.json({ error: `${name} ${r.status}` }, { status: r.status });
        const pkg = (await r.json()) as { name?: string; version?: string; main?: string };
        return Response.json({
          name: pkg.name || name,
          version: pkg.version,
          main: pkg.main,
        });
      },
    },
  },
});
