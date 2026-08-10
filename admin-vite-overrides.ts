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
  //   admin-bundler generates the @vite/client bootstrap, it READS LITERAL
  //   VALUES OUT OF `config.server.hmr` (host, port, clientPort, protocol,
  //   path) and HARD-CODES them as `__HMR_PORT__`, `__HMR_HOSTNAME__`,
  //   `__HMR_PROTOCOL__`, `__HMR_CLIENT_PORT__` constants into the shipped
  //   client.mjs source.  Text substitution via `config.define` does NOT
  //   work because @vite/client is an internal Vite module that goes
  //   through a dedicated transform pipeline that bypasses user-defined
  //   defines — evidence from the live deployment:
  //     config.define.__HMR_CLIENT_PORT__ = "(location.port || ...)"
  //     was correctly set (confirmed via [admin-vite-config] banner) but
  //     the browser still connected to `wss://...:9001/...`, i.e. the
  //     baked-in value was still hmr.port (9001) instead of the expression.
  //
  //   FIX: compute the LITERAL browser-facing HMR endpoint values at
  //   vite-function-call time and write them directly into server.hmr.
  //   Source of truth, in priority order:
  //     1. Explicit HMR_HOSTNAME / HMR_PROTOCOL / HMR_CLIENT_PORT env vars
  //        set by the operator / docker-entrypoint.sh
  //     2. Parsed from ADMIN_URL env var (e.g. "https://medusa.example.com:8443"
  //        → wss, medusa.example.com, 8443) — entrypoint parses this too
  //        so either env source ends up in process.env.HMR_* below
  //     3. Sensible defaults: hostname=null (location.hostname), protocol=ws,
  //        clientPort=null (falls back to hmr.port = 9001 — only OK for
  //        direct localhost dev, NOT behind a reverse proxy)
  //
  //   clientPort: if the public port is 80 or 443 we MUST pass the literal
  //   empty string "", because browsers omit location.port for standard
  //   ports; @vite/client interprets "" as "no explicit clientPort, keep
  //   the page's implied port" and will NOT fall through to hmr.port.
  //   Any non-standard port (8443, 9810, etc.) is a literal number-string.
  function _fromEnvOrAdminUrl(key: string) {
    const v = process.env[key];
    return v && String(v).trim() ? String(v).trim() : undefined;
  }
  const hmrHost = _fromEnvOrAdminUrl("HMR_HOSTNAME") ?? null;
  const hmrProtocol = _fromEnvOrAdminUrl("HMR_PROTOCOL") ?? "ws";
  const hmrClientPortEnv = _fromEnvOrAdminUrl("HMR_CLIENT_PORT");
  const hmrClientPort =
    hmrClientPortEnv === "80" || hmrClientPortEnv === "443"
      ? ""
      : (hmrClientPortEnv ?? null);

  config.server.hmr = {
    port: 9001,
    path: "/vite-hmr",
    host: hmrHost,
    protocol: hmrProtocol as "ws" | "wss",
    clientPort: hmrClientPort as any,
  };

  // Belt-and-suspenders: define the same variables so EVEN IF a random
  // business JS file uses them, the values match what's baked into
  // @vite/client.  (Vite define does TEXT substitution — no extra quotes.)
  config.define = config.define || {};
  config.define.__HMR_HOSTNAME__ = hmrHost
    ? JSON.stringify(hmrHost)
    : "location.hostname";
  config.define.__HMR_PROTOCOL__ = JSON.stringify(hmrProtocol);
  const explicitClientPortLiteral =
    hmrClientPort === ""
      ? "''"
      : hmrClientPort
        ? JSON.stringify(hmrClientPort)
        : "(location.port || (location.protocol === 'https:' ? '443' : '80'))";
  config.define.__HMR_CLIENT_PORT__ = explicitClientPortLiteral;

  // (C2) Keep CJS deps optimized, but NEVER do lazy-route triggered
  //      on-demand re-discovery.
  //
  //      History: `optimizeDeps.disabled = "dev"` was tried first but
  //      caused a HARD SyntaxError on React v18's jsx-runtime:
  //        ".../react/jsx-runtime.js does not provide an export named 'jsx'"
  //      because `react/jsx-runtime` is a COMMONJS module that relies on
  //      esbuild CJS→ESM interop to expose named exports.  You CANNOT just
  //      load it via @fs as raw ESM; it MUST be pre-bundled.
  //
  //      The root cause of the earlier 404 hash-mismatch bugs was NOT the
  //      existence of optimizeDeps itself, but Bun/esbuild race conditions
  //      on LAZY re-discovery.  Flow:
  //        1. Vite boots → optimizeDeps scans admin-bundler's explicit
  //           `include` list → writes react/react-dom/etc chunks +
  //           _metadata.json → ALL hashes are stable & consistent.
  //        2. User navigates into a route with a dynamic `import(...)`
  //           (e.g. region-list page) → Vite's DISCOVERY pipeline adds
  //           the new chunk KEY to _metadata.json with a new hash.
  //        3. Under Bun, the esbuild WRITE for that new chunk races the
  //           transform pipeline: metadata + parent chunks bake hash "X"
  //           but esbuild actually writes hash "Y" to disk → 404 when
  //           the browser follows the dynamic import URL with hash X.
  //
  //      `optimizeDeps.noDiscovery = true` tells Vite:
  //        • STILL run optimizeDeps at boot (react CJS gets the interop
  //          → `export const jsx` exists → SyntaxError gone).
  //        • NEVER re-scan imports at runtime when lazy route chunks
  //          are loaded.  Any module NOT on the boot-time `include` list
  //          simply loads as raw native ESM via @fs URLs (that's fine
  //          for ESM-only admin route packages — they never had CJS
  //          interop problems to begin with).
  //
  //      As a belt-and-suspenders safety net, we ALSO append React
  //      explicitly, in case admin-bundler ever drops them from their
  //      own include list (should never happen, but cheap to add).
  config.optimizeDeps = config.optimizeDeps || {};
  config.optimizeDeps.noDiscovery = true;
  const existingInclude = Array.isArray(config.optimizeDeps.include)
    ? config.optimizeDeps.include
    : config.optimizeDeps.include
      ? [config.optimizeDeps.include]
      : [];
  // CJS packages that break if loaded raw via @fs URLs (no ESM interop).
  // The admin-bundler already includes most of these; we re-list them
  // explicitly so noDiscovery mode doesn't accidentally drop them.
  const _cjsCritical = [
    "react",
    "react/jsx-runtime",
    "react/jsx-dev-runtime",
    "react-dom",
    "react-dom/client",
    "react-dom/server",
    "react-router-dom",
    "react-i18next",
    "i18next",
    "@tanstack/react-query",
    "@medusajs/ui",
    "@medusajs/admin-shared",
    "@medusajs/dashboard",
    "@medusajs/js-sdk",
    "@medusajs/draft-order/admin",
  ];
  config.optimizeDeps.include = Array.from(
    new Set([...existingInclude, ..._cjsCritical]),
  );

  // (C3) Diagnostic — log HMR + optimizeDeps config at boot so operators
  //      can confirm the customised vite function is ACTUALLY loaded by
  //      grepping `docker logs medusa | grep [admin-vite-config]`.
  try {
    const _banner = [
      "[admin-vite-config] ===== admin-vite-overrides.ts ACTIVE =====",
      `[admin-vite-config] server.allowedHosts = ${String(config.server?.allowedHosts)}`,
      `[admin-vite-config] server.host = ${String(config.server?.host)}`,
      `[admin-vite-config] server.fs.strict = ${String(config.server?.fs?.strict)}`,
      `[admin-vite-config] server.fs.allow = ${JSON.stringify(config.server?.fs?.allow ?? [])}`,
      `[admin-vite-config] server.hmr.port = ${String(config.server?.hmr?.port)}`,
      `[admin-vite-config] server.hmr.path = ${String(config.server?.hmr?.path)}`,
      `[admin-vite-config] server.hmr.host = ${JSON.stringify(config.server?.hmr?.host ?? null)}`,
      `[admin-vite-config] server.hmr.protocol = ${JSON.stringify(config.server?.hmr?.protocol ?? null)}`,
      `[admin-vite-config] server.hmr.clientPort = ${JSON.stringify(config.server?.hmr?.clientPort ?? null)}`,
      `[admin-vite-config] define.__HMR_HOSTNAME__ = ${String(config.define?.__HMR_HOSTNAME__)}`,
      `[admin-vite-config] define.__HMR_PROTOCOL__ = ${String(config.define?.__HMR_PROTOCOL__)}`,
      `[admin-vite-config] define.__HMR_CLIENT_PORT__ = ${String(config.define?.__HMR_CLIENT_PORT__)}`,
      `[admin-vite-config] optimizeDeps.noDiscovery = ${String(config.optimizeDeps.noDiscovery)}`,
      `[admin-vite-config] optimizeDeps.include count = ${config.optimizeDeps.include.length}`,
      `[admin-vite-config] resolve.plugins resolve-abs-fs-paths = ${(config.resolve?.plugins ?? []).some((p) => p && (p as any).name === "resolve-abs-fs-paths")}`,
      "[admin-vite-config] ==================================================",
    ].join("\n");
    // Use `console` only when available — this file also gets `require()`-ed
    // by the entrypoint's sed pipeline which runs under Bun's top-level scope.
    if (typeof console !== "undefined" && typeof console.log === "function") {
      console.log(_banner);
    }
  } catch {
    // Diagnostic must NEVER crash the vite function; swallow everything.
  }

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
