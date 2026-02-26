import type { FastifyPluginAsync } from "fastify";

import { config } from "../config";

export const realtimeRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.post("/session", {
    onRequest: [fastify.authenticate]
  }, async (_request, reply) => {
    const response = await fetch("https://api.openai.com/v1/realtime/sessions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.OPENAI_API_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ model: config.OPENAI_REALTIME_MODEL })
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      fastify.log.error({ status: response.status, body: text }, "OpenAI realtime session creation failed");
      return reply.code(502).send({ error: "No se pudo crear la sesión con OpenAI" });
    }

    const data = await response.json() as {
      client_secret?: { value?: string; expires_at?: number };
      model?: string;
    };

    const token = data.client_secret?.value;
    if (!token) {
      return reply.code(502).send({ error: "Respuesta inesperada de OpenAI" });
    }

    return reply.send({
      ephemeralToken: token,
      expiresAt: data.client_secret?.expires_at ?? null,
      model: data.model ?? config.OPENAI_REALTIME_MODEL
    });
  });
};
