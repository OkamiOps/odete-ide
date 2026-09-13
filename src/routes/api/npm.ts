import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/api/npm")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const u = new URL(request.url);
        const name = u.searchParams.get("name")?.trim();
        if (!name) return Response.json({ error: "name" }, { status: 400 });
        const r = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/latest`);
        if (!r.ok) return Response.json({ error: `${name} ${r.status}` }, { status: r.status });
        const pkg = (await r.json()) as {
          name?: string;
          version?: string;
          main?: string;
          dist?: { tarball?: string };
        };
        if (u.searchParams.get("pack") && pkg.dist?.tarball) {
          const tgz = await fetch(pkg.dist.tarball);
          if (!tgz.ok) return Response.json({ error: "tarball" }, { status: tgz.status });
          return new Response(tgz.body, {
            headers: { "Content-Type": "application/gzip", "Cache-Control": "max-age=3600" },
          });
        }
        return Response.json({
          name: pkg.name || name,
          version: pkg.version,
          main: pkg.main,
          tarball: pkg.dist?.tarball,
        });
      },
    },
  },
});
