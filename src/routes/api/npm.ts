import { createFileRoute } from "@tanstack/react-router";
import { maxSatisfying } from "@/lib/workspace/semver";

type Pkg = {
  name?: string;
  version?: string;
  main?: string;
  module?: string;
  dependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
  dist?: { tarball?: string };
};

function enc(name: string) {
  return name.startsWith("@") ? name.replace("/", "%2F") : encodeURIComponent(name);
}

function isExact(ver?: string) {
  return !!ver && /^\d+\.\d+\.\d+/.test(ver.replace(/^v/, ""));
}

function jsonOf(pkg: Pkg, name: string) {
  return {
    name: pkg.name || name,
    version: pkg.version,
    main: pkg.main,
    module: pkg.module,
    dependencies: pkg.dependencies ?? {},
    peerDependencies: pkg.peerDependencies ?? {},
    optionalDependencies: pkg.optionalDependencies ?? {},
    tarball: pkg.dist?.tarball,
  };
}

export const Route = createFileRoute("/api/npm")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const u = new URL(request.url);
        const name = u.searchParams.get("name")?.trim();
        const ver = u.searchParams.get("ver")?.trim() || "";
        if (!name) return Response.json({ error: "name" }, { status: 400 });
        const id = enc(name);

        if (u.searchParams.get("pack")) {
          const exact = isExact(ver) ? ver.replace(/^v/, "") : "";
          const url = exact
            ? `https://registry.npmjs.org/${id}/${exact}`
            : `https://registry.npmjs.org/${id}/latest`;
          const r = await fetch(url);
          if (!r.ok) return Response.json({ error: `${name} ${r.status}` }, { status: r.status });
          const pkg = (await r.json()) as Pkg;
          if (!pkg.dist?.tarball) return Response.json({ error: "tarball" }, { status: 404 });
          const tgz = await fetch(pkg.dist.tarball);
          if (!tgz.ok) return Response.json({ error: "tarball" }, { status: tgz.status });
          return new Response(tgz.body, {
            headers: { "Content-Type": "application/gzip", "Cache-Control": "max-age=3600" },
          });
        }

        if (isExact(ver) && !/[\^~><*]/.test(ver)) {
          const r = await fetch(`https://registry.npmjs.org/${id}/${ver.replace(/^v/, "")}`);
          if (r.ok) {
            const pkg = (await r.json()) as Pkg;
            return Response.json(jsonOf(pkg, name));
          }
        }

        const pack = await fetch(`https://registry.npmjs.org/${id}`, {
          headers: { Accept: "application/vnd.npm.install-v1+json" },
        });
        if (pack.ok) {
          const body = (await pack.json()) as {
            name?: string;
            "dist-tags"?: { latest?: string };
            versions?: Record<string, Pkg>;
          };
          const versions = Object.keys(body.versions ?? {});
          const picked =
            maxSatisfying(versions, ver) || body["dist-tags"]?.latest || versions[versions.length - 1];
          const pkg = (picked && body.versions?.[picked]) || null;
          if (pkg?.version) return Response.json(jsonOf(pkg, name));
        }

        const latest = await fetch(`https://registry.npmjs.org/${id}/latest`);
        if (!latest.ok) return Response.json({ error: `${name} ${latest.status}` }, { status: latest.status });
        const pkg = (await latest.json()) as Pkg;
        return Response.json(jsonOf(pkg, name));
      },
    },
  },
});
