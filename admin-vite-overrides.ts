// Vite config overrides for the Medusa admin dev server.
//
// Imported by medusa-config.ts (via a runtime patch in docker-entrypoint.sh)
// and returned as the `admin.vite` function.
//
// (A) allowedHosts=true / host=true — reverse-proxy friendly
// (B) server.fs.strict=false + /app/medusa in fs.allow
// (C) server.hmr — fixed port 9001, clientPort "", path "/vite-hmr"
// (D) resolve-abs-fs-paths plugin (enforce: "pre")
//     ROOT CAUSE FIX for admin blank page.
//     The i18n virtual module emits:
//       import i18nTranslations0 from "/app/medusa/src/admin/i18n/index.ts"
//     Vite base="/app/" causes resolveId to strip the base prefix, leaving
//     "/medusa/src/admin/i18n/index.ts" which does NOT exist on disk.
//     This plugin tries BOTH the original and base-restored (prepend "/app")
//     forms and returns whichever exists on disk.

import fs from "node:fs";

const BASE = "/app"; // Vite base without trailing slash

const adminVite = (config: any): any => {
  config.server = config.server || {};

  // (A)
  config.server.allowedHosts = true;
  config.server.host = true;

  // (B)
  config.server.fs = config.server.fs || {};
  config.server.fs.strict = false;
  config.server.fs.allow = [
    ...((config.server.fs.allow as string[]) || []),
    "/app/medusa",
    "/app/medusa/src",
  ];

  // (C) server.hmr
  //     port      = 9001 — container-internal port the Vite HMR WebSocket
  //                         server listens on. NEVER random because the
  //                         shared-port proxy routes /vite-hmr(*) → 9001.
  //     clientPort          — the PORT used by the BROWSER to connect.
  //                         Defaults to `hmr.port` if unset/falsy.  We
  //                         cannot hardcode 8443 because the reverse proxy
  //                         external port differs per deployment, so we
  //                         let the user override via HMR_CLIENT_PORT env
  //                         var.  If the env var is NOT set, we leave
  //                         clientPort undefined which tells @vite/client
  //                         to "follow the page URL" — it uses
  //                         location.port (the HTTPS port the user
  //                         actually visited, e.g. 8443).
  //     path      = "/vite-hmr" — IMPORTANT: Vite PREPENDS base="/app/"
  //                         to hmr.path when computing the browser-facing
  //                         HMR URL, so the browser actually connects to
  //                         "/app/vite-hmr".  shared-port-proxy.ts handles
  //                         both "/vite-hmr" and "/app/vite-hmr" via an
  //                         "ends with /vite-hmr" match.
  //     host/protocol = undefined → @vite/client falls back to
  //                         location.hostname / location.protocol, i.e.
  //                         matches the page URL exactly (perfect for a
  //                         reverse-proxy setup).
  const hmrClientPortEnv = process.env.HMR_CLIENT_PORT;
  config.server.hmr = {
    port: 9001,
    clientPort: hmrClientPortEnv ? Number(hmrClientPortEnv) : undefined,
    path: "/vite-hmr",
  };

  // (D) resolve.alias — belt-and-suspenders fallback.
  //     Works EVEN IF admin-bundler overwrites config.plugins after our
  //     function returns (the alias is in config.resolve, not config.plugins).
  //     Maps base-stripped "/medusa/..." back to "/app/medusa/..." on disk.
  config.resolve = config.resolve || {};
  const existingAliases = Array.isArray(config.resolve.alias)
    ? config.resolve.alias
    : config.resolve.alias
      ? [config.resolve.alias]
      : [];
  config.resolve.alias = [
    ...existingAliases,
    { find: /^\/medusa\//, replacement: "/app/medusa/" },
  ];

  // (D2) resolve-abs-fs-paths plugin — primary fix.
  config.plugins = [
    ...(config.plugins || []),
    {
      name: "resolve-abs-fs-paths",
      enforce: "pre",
      resolveId(source: string) {
        if (
          typeof source !== "string" ||
          !source.startsWith("/") ||
          source.startsWith("//")
        ) {
          return null;
        }
        // Build candidate paths: the original source AND base-restored form.
        const candidates: string[] = [source];
        if (!source.startsWith("/app")) {
          // Base was stripped — restore it: "/medusa/..." → "/app/medusa/..."
          candidates.push(BASE + source);
        } else if (source.startsWith("/app/")) {
          // Original form — also try stripped (in case we run pre-strip and
          // Vite re-resolves post-strip later): "/app/medusa/..." → "/medusa/..."
          candidates.push(source.slice(BASE.length));
        }
        for (const c of candidates) {
          try {
            if (fs.existsSync(c) && fs.statSync(c).isFile()) {
              console.log(`[resolve-abs-fs-paths] ${source} → ${c}`);
              return c;
            }
          } catch {
            // fs error for this candidate — try next
          }
        }
        return null;
      },
    },
  ];

  return config;
};

export default adminVite;
