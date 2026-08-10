// Shared-port reverse proxy for the bun-medusa dev container.
//
// Problem: The embedded admin Vite runs in middlewareMode, so its HMR
// WebSocket cannot share the same HTTP server as Medusa — Vite opens its
// own listener on a SECOND port (we pin it to container-internal 9001).
// Exposing two ports externally forces the user to maintain two reverse-
// proxy entries plus an extra docker port mapping.
//
// Solution: This tiny proxy binds to container port 9000 (the only one
// exposed) and dispatches based on request path + Upgrade header:
//
//   • WebSocket Upgrade + pathname contains "vite-hmr" segment
//                                 → 127.0.0.1:9001 (Vite HMR)
//   • Everything else (HTTP / WebSocket on any other path)
//                                 → 127.0.0.1:9002 (Medusa)
//
// The "contains" match (instead of starts-with) is intentional because
// Vite configures base="/app/" AND automatically prepends the base to
// hmr.path.  So even though admin-vite-overrides.ts sets hmr.path="/vite-hmr",
// the browser actually requests "/app/vite-hmr" (or "/<anything>/vite-hmr"
// if base ever changes).  Matching on "ends with /vite-hmr plus query/hash"
// catches every base the user configures.
//
// The user only needs one docker port mapping (HOST:9810→9000) and one
// reverse-proxy location block that also passes WebSocket Upgrade
// headers (single catch-all works for both admin HTTP AND HMR WS).

const MAIN_PORT = 9002;
const HMR_PORT = 9001;
// Match either `/vite-hmr` exactly, or any path that ends with `/vite-hmr`
// (with optional query string).  Handles Vite prepending base="/app/" to it.
const HMR_PATH_SEGMENT = "/vite-hmr";
const LISTEN_PORT = 9000;
const UPSTREAM_HOST = "127.0.0.1";

interface WSContext {
  upstreamWsUrl: string;
}

// Map Bun server-side WS -> upstream (standard) WS for bidirectional relay.
// Using any-typed storage keeps the file compilable without DOM lib types.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const pairs = new WeakMap<any, WebSocket>();

function isHmrPath(pathname: string): boolean {
  return (
    pathname.endsWith(HMR_PATH_SEGMENT) ||
    pathname.includes(HMR_PATH_SEGMENT + "?") ||
    pathname.includes(HMR_PATH_SEGMENT + "/")
  );
}

function pickUpstreamPort(req: Request, url: URL): number {
  const isUpgrade =
    (req.headers.get("upgrade") || "").toLowerCase() === "websocket";
  return isHmrPath(url.pathname) && isUpgrade ? HMR_PORT : MAIN_PORT;
}

const server = Bun.serve<WSContext>({
  port: LISTEN_PORT,
  hostname: "0.0.0.0",

  async fetch(req, svr) {
    const url = new URL(req.url);
    const port = pickUpstreamPort(req, url);
    const isUpgrade =
      (req.headers.get("upgrade") || "").toLowerCase() === "websocket";

    if (isUpgrade) {
      const scheme = port === HMR_PORT ? "ws" : "ws";
      const upstreamWsUrl = `${scheme}://${UPSTREAM_HOST}:${port}${url.pathname}${url.search}`;
      const ok = svr.upgrade(req, { upstreamWsUrl } as WSContext);
      if (!ok)
        return new Response("Bad Request (upgrade rejected)", { status: 400 });
      // Bun replaces this response with the 101 Switching Protocols frame;
      // the status code here is not actually sent.
      return new Response(null, { status: 101 });
    }

    const target = `http://${UPSTREAM_HOST}:${port}${url.pathname}${url.search}`;
    try {
      return await fetch(target, {
        method: req.method,
        headers: req.headers,
        // @ts-expect-error — Bun supports Request body streaming via duplex
        body: req.body,
        duplex: "half",
        redirect: "manual",
      });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      return new Response(
        `[bun-medusa proxy] Upstream port ${port} unreachable: ${msg}\n`,
        { status: 502 },
      );
    }
  },

  websocket: {
    open(ws) {
      const ctx = ws.data as WSContext;
      try {
        const upstream = new WebSocket(
          ctx.upstreamWsUrl,
        ) as unknown as WebSocket;

        // Upstream → client
        upstream.addEventListener("message", (e: MessageEvent) => {
          // Bun WebSocket.send accepts string | ArrayBuffer | Uint8Array
          try {
            (ws as unknown as { send: (d: unknown) => void }).send(e.data);
          } catch {
            /* client already closed */
          }
        });
        upstream.addEventListener("close", () => {
          try {
            (ws as unknown as { close: () => void }).close();
          } catch {
            /* noop */
          }
        });
        upstream.addEventListener("error", () => {
          try {
            (ws as unknown as { close: () => void }).close();
          } catch {
            /* noop */
          }
        });

        pairs.set(ws, upstream);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[proxy] HMR upstream connect failed: ${msg}`);
        try {
          (ws as unknown as { close: () => void }).close();
        } catch {
          /* noop */
        }
      }
    },

    message(ws, message) {
      const upstream = pairs.get(ws);
      if (!upstream) return;
      if (upstream.readyState !== WebSocket.OPEN) return;
      try {
        upstream.send(
          message as string | ArrayBufferLike | Blob | ArrayBufferView,
        );
      } catch {
        /* upstream closed mid-send */
      }
    },

    close(ws) {
      const upstream = pairs.get(ws);
      if (upstream) {
        try {
          upstream.close();
        } catch {
          /* noop */
        }
        pairs.delete(ws);
      }
    },
  },
});

console.log(
  `[proxy] Shared-port reverse proxy listening on 0.0.0.0:${server.port}`,
);
console.log(
  `[proxy]   HTTP + non-HMR WS   → 127.0.0.1:${MAIN_PORT}  (Medusa + Vite middleware)`,
);
console.log(
  `[proxy]   WS  *${HMR_PATH_SEGMENT}*           → 127.0.0.1:${HMR_PORT}  (Vite HMR fixed port)`,
);
