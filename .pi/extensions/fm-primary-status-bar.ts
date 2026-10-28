// Firstmate canonical status bar for Pi's native custom-footer API.
import { execFile } from "node:child_process";
import { mkdir, open } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

type SessionEntry = {
  type?: unknown;
  message?: {
    role?: unknown;
    usage?: {
      cost?: {
        total?: unknown;
      };
    };
  };
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const renderer = `${root}/bin/fm-status-bar.sh`;
const refreshMilliseconds = 1000;
const staleMilliseconds = 10_000;
const collectionMilliseconds = 1500;
const unavailable = "\u001b[91;1m⚓ STATUS UNAVAILABLE\u001b[0m";

// Only fixed categories and numeric process metadata reach this bounded local log.
// In particular, neither stderr nor arguments can disclose session content.
async function logFailure(detail: string): Promise<void> {
  const state = process.env.FM_STATE_OVERRIDE || resolve(
    process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root, "state",
  );
  try {
    await mkdir(state, { recursive: true });
    const file = await open(resolve(state, "pi-status-bar.log"), "a", 0o600);
    try {
      if ((await file.stat()).size >= 32_768) await file.truncate(0);
      await file.writeFile(`${new Date().toISOString()} ${detail}\n`);
    } finally {
      await file.close();
    }
  } catch {
    // Diagnostics must never break the footer or fall back to the transcript.
  }
}

function sessionCost(ctx: ExtensionContext): number {
  let cost = 0;
  for (const entry of ctx.sessionManager.getEntries() as SessionEntry[]) {
    if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
    const entryCost = entry.message.usage?.cost?.total;
    if (typeof entryCost === "number" && Number.isFinite(entryCost)) cost += entryCost;
  }
  return cost;
}

function rendererArguments(pi: ExtensionAPI, ctx: ExtensionContext): string[] {
  const usage = ctx.getContextUsage();
  // Pi's percent is already context used (0-100); pass it through unchanged.
  const used =
    usage?.percent == null ? "--" : String(Math.max(0, Math.min(100, Math.floor(usage.percent))));
  return [
    "--adapter",
    "pi",
    "--model",
    ctx.model?.id || "--",
    "--effort",
    String(pi.getThinkingLevel?.() || "--"),
    "--context-used",
    used,
    "--quota-used",
    "--",
    "--cost",
    String(sessionCost(ctx)),
  ];
}

export default function (pi: ExtensionAPI) {
  if (process.env.FM_PRIMARY_HARNESS !== "pi") return;

  let disposeFooter: (() => void) | undefined;
  pi.on("session_shutdown", () => disposeFooter?.());
  pi.on("session_start", (_event, ctx) => {
    disposeFooter?.();
    if (ctx.mode !== "tui") return;
    ctx.ui.setFooter((tui) => {
      // A replacement factory must retire the previous instance too.
      disposeFooter?.();
      let disposed = false;
      let cached = "";
      let goodAt = 0;
      let failed = false;
      let lastDiagnosticAt = -Infinity;
      let child: ReturnType<typeof execFile> | undefined;

      const collect = () => {
        if (disposed || child) return;
        child = execFile(renderer, rendererArguments(pi, ctx), {
          encoding: "utf8",
          env: process.env,
          timeout: collectionMilliseconds,
          killSignal: "SIGKILL",
          maxBuffer: 16_384,
        }, (error, stdout) => {
          if (disposed) return;
          child = undefined;
          const row = stdout.replace(/\r?\n$/, "");
          failed = !!error || !row.trim();
          if (!failed) {
            cached = row;
            goodAt = Date.now();
          } else if (Date.now() - lastDiagnosticAt >= 60_000) {
            lastDiagnosticAt = Date.now();
            const reason = error?.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER" ? "output-limit"
              : error?.killed && error.signal === "SIGKILL" ? "timeout"
              : error ? "exit" : "empty-output";
            // Codes/signals are constrained, never interpolated error messages.
            const status = typeof error?.code === "number" ? error.code : "null";
            const signal = error?.signal === "SIGKILL" ? "SIGKILL" : error?.signal ? "other" : "none";
            void logFailure(`reason=${reason} status=${status} signal=${signal}`);
          }
          tui.requestRender();
        });
      };
      const refresh = setInterval(() => {
        collect();
        tui.requestRender();
      }, refreshMilliseconds);
      refresh.unref();
      const dispose = () => {
        if (disposed) return;
        disposed = true;
        clearInterval(refresh);
        child?.kill("SIGKILL");
        child = undefined;
      };
      disposeFooter = dispose;
      collect();

      return {
        dispose,
        invalidate() {},
        render(width: number): string[] {
          if (width <= 0) return [""];
          const age = Date.now() - goodAt;
          const row = !cached ? (failed ? unavailable : "⚓ STATUS LOADING")
            : age >= staleMilliseconds
              ? `\u001b[93;1m⚠ STALE ${Math.floor(age / 1000)}s\u001b[0m │ ${cached}`
              : cached;
          return [truncateToWidth(row, width, "")];
        },
      };
    });
  });
}
