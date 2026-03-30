import type { FastifyPluginAsync } from "fastify";

import { config } from "../config";

export const realtimeRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.get("/groq-key", {
    onRequest: [fastify.authenticate]
  }, async (_request, reply) => {
    const key = config.GROQ_API_KEY;
    if (!key) {
      return reply.code(500).send({ error: "GROQ_API_KEY no configurada en el servidor" });
    }
    return reply.send({ apiKey: key });
  });
};
