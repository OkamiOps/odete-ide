import { createFileRoute } from "@tanstack/react-router";
import { streamProviderTurn } from "@/lib/agent/stream.server";
import type { StreamEvt } from "@/lib/agent/stream-types";
import type { AgentMessage } from "@/lib/agent/server";
import type { AgentId } from "@/lib/agent/providers";
import type { AgentMode } from "@/lib/agent/tools";

export const Route = createFileRoute("/api/agent")({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const data = (await request.json()) as {
          messages: AgentMessage[];
          fileList: string;
          provider: AgentId;
          model: string;
          access?: string;
          accountId?: string;
          skills?: string;
          mode?: AgentMode;
          effort?: string;
        };
        const stream = new ReadableStream({
          async start(controller) {
            const enc = new TextEncoder();
            const emit = (e: StreamEvt) => {
              controller.enqueue(enc.encode(`data: ${JSON.stringify(e)}\n\n`));
            };
            try {
              const result = await streamProviderTurn(data, emit);
              if (!result.ok) emit({ t: "error", e: result.error });
            } catch (err) {
              emit({ t: "error", e: err instanceof Error ? err.message : "falha no stream" });
            } finally {
              emit({ t: "done" });
              controller.close();
            }
          },
        });
        return new Response(stream, {
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            Connection: "keep-alive",
          },
        });
      },
    },
  },
});