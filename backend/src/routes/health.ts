import type { FastifyPluginAsync } from "fastify";

export const healthRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.get("/health", async () => {
    return {
      ok: true,
      service: "easy-sales-backend",
      timestamp: new Date().toISOString()
    };
  });
};
