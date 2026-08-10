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

  // (C) server.hmr + define overrides — make browser-side HMR URL follow the
  //                                      page URL at runtime, never hardcoded.
  // ---------------------------------------------------------------------------
  //
  // Container side (Vite HMR WebSocket listener):
  //   port = 9001  — fixed internal listener.  The in-container shared-port
  //                  proxy routes any WebSocket Upgrade whose pathname
  //                  contains "/vite-hmr" segment to 127.0.0.1:9001.
  //   path = "/vite-hmr" — Vite prepends base="/app/" automatically, so the
  //                  browser actually hits "/app/vite-hmr"; the proxy uses
  //                  a path-segment match (not startsWith) so both forms
  //                  route to 9001 regardless of base.
  //
  // Browser side (@vite/client chooses host/protocol/port from these defines):
  //   Vite v5 DOES NOT leave host/protocol/port blank and fall back to
  //   location.* the way earlier versions did.  Instead it bakes
  //   __HMR_HOSTNAME__ / __HMR_PROTOCOL__ / __HMR_CLIENT_PORT__ into the
  //   compiled @vite/client source via `define`.  Our previous attempt
  //   relied on hmr.host/protocol/clientPort being undefined, which made
  //   Vite's defaults hardcode hmr.port (9001) as the browser-facing port
  //   and 'ws' as the protocol — both wrong behind an HTTPS reverse proxy
  //   on a non-standard port like 8443.
  //
  //   FIX: use config.define to OVERWRITE the injected HMR constants with
  //   raw JS expressions that evaluate AT RUNTIME in the browser against
  //   `location`.  `define` values are TEXT substitutions (no extra
  //   quoting), so writing `"location.hostname"` injects the literal
  //   expression, not a JSON-stringified string.  This works for EVERY
  //   deployment without any env vars — whether the user terminates on
  //   :443, :8443, :80, :8080, or any other port.
  //
  //   __HMR_CLIENT_PORT__ expression handles standard ports too: browsers
  //   leave location.port empty for :80 / :443, and an empty string is
  //   falsy, so we fall back to literal '443' / '80' to prevent the
  //   fallback `__HMR_CLIENT_PORT__ || __HMR_PORT__` from picking up
  //   __HMR_PORT__ (the container-internal 9001 listener port).
  config.server.hmr = {
    port: 9001,
    path: "/vite-hmr",
  };

  // Explicit HMR_CLIENT_PORT override (rare — used ONLY when the reverse
  // proxy exposes HMR on a DIFFERENT port than the admin HTTP page, e.g.
  // if user still wants a separate /vite-hmr location entry).  When set,
  // we bake that literal number into __HMR_CLIENT_PORT__.  Otherwise we
  // bake the location.port expression.
  const explicitClientPort = process.env.HMR_CLIENT_PORT
    ? JSON.stringify(Number(process.env.HMR_CLIENT_PORT))
    : "(location.port || (location.protocol === 'https:' ? '443' : '80'))";

  config.define = config.define || {};
  config.define.__HMR_HOSTNAME__ = "location.hostname";
  config.define.__HMR_PROTOCOL__ =
    "(location.protocol === 'https:' ? 'wss' : 'ws')";
  config.define.__HMR_CLIENT_PORT__ = explicitClientPort;

  // (C2) Disable Vite optimizeDeps entirely in dev mode.
  //      Root cause of repeatedly-reported "Failed to fetch dynamically
  //      imported module" with HTTP 404: Medusa's admin-bundler lazily
  //      triggers optimizeDeps discovery whenever the user navigates an
  //      admin route that imports a new page-level chunk.  Under Bun,
  //      the esbuild prebundling step occasionally produces chunk files
  //      whose <contentHash> suffix disagrees with the _metadata.json
  //      hash the transform pipeline injects into parent chunks that
  //      dynamic-import them — the browser loads
  //        chunk-A (stale, baked with hash "X" of chunk-B)
  //        → fetches chunk-B at hash X
  //        → disk has chunk-B at hash Y (≠X)
  //        → HTTP 404
  //      Even deleting node_modules/.vite before every boot only fixes
  //      the initial boot; navigating between admin routes re-triggers
  //      lazy discovery and the hash mismatch can repeat.
  //
  //      `optimizeDeps.disabled = "dev"` tells Vite to NEVER prebundle.
  //      The browser simply loads EVERY admin route-module as a plain
  //      native ESM fetch directly from node_modules via @fs/ paths.
  //      Modern browsers handle hundreds of parallel ESM requests fine;
  //      trade a bit more first-visit request count for ZERO 404s and
  //      zero Bun/esbuild compatibility surprises.
  config.optimizeDeps = config.optimizeDeps || {};
  config.optimizeDeps.disabled = "dev";

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
