import cors from "@fastify/cors";
import jwt from "@fastify/jwt";
import multipart from "@fastify/multipart";
import Fastify from "fastify";

import { config } from "./config";
import { db } from "./db";
import { Mailer } from "./mailer";
import { runMigrations } from "./migrations";
import { ensureCollection } from "./qdrant";
import { authRoutes } from "./routes/auth";
import { googleAuthRoutes } from "./routes/google-auth";
import { dataRoutes } from "./routes/data";
import { documentRoutes } from "./routes/documents";
import { healthRoutes } from "./routes/health";
import { realtimeRoutes } from "./routes/realtime";

async function buildServer() {
  const fastify = Fastify({
    logger: true,
    bodyLimit: 15 * 1024 * 1024 // 15 MB for multipart file uploads
  });

  await fastify.register(cors, {
    origin: config.CORS_ORIGIN === "*" ? true : config.CORS_ORIGIN.split(",").map((item) => item.trim())
  });

  await fastify.register(jwt, {
    secret: config.JWT_SECRET
  });

  await fastify.register(multipart, {
    limits: { fileSize: 10 * 1024 * 1024 } // 10 MB
  });

  fastify.decorate("mailer", new Mailer(config));

  fastify.decorate("authenticate", async (request, reply) => {
    try {
      await request.jwtVerify();
    } catch (_error) {
      return reply.code(401).send({ error: "Unauthorized" });
    }
  });

  await fastify.register(healthRoutes, { prefix: "/api" });
  await fastify.register(authRoutes, { prefix: "/api/auth" });
  await fastify.register(googleAuthRoutes, { prefix: "/api/auth/google" });
  await fastify.register(dataRoutes, { prefix: "/api/data" });
  await fastify.register(documentRoutes, { prefix: "/api/data/documents" });
  await fastify.register(realtimeRoutes, { prefix: "/api/realtime" });

  return fastify;
}

async function start() {
  await runMigrations(db);
  await ensureCollection();

  const server = await buildServer();

  const closeSignals: NodeJS.Signals[] = ["SIGINT", "SIGTERM"];
  for (const signal of closeSignals) {
    process.on(signal, async () => {
      await server.close();
      await db.end();
      process.exit(0);
    });
  }

  await server.listen({
    host: config.HOST,
    port: config.PORT
  });
}

start().catch(async (error) => {
  // eslint-disable-next-line no-console
  console.error(error);
  await db.end();
  process.exit(1);
});
