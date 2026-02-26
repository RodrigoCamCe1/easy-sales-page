import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";

import { db } from "../db";

function getUserId(request: { user?: unknown }): string {
  const payload = request.user as { sub?: string } | undefined;
  const userId = payload?.sub?.trim() ?? "";
  if (!userId) {
    throw new Error("Missing user id in JWT");
  }
  return userId;
}

const putAgentsConfigSchema = z.object({
  config: z.record(z.string(), z.unknown())
});

const putConversationsSchema = z.object({
  conversations: z.array(z.record(z.string(), z.unknown()))
});

const addConversationSchema = z.object({
  conversation: z.record(z.string(), z.unknown())
});

export const dataRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.get("/agents-config", { preHandler: [fastify.authenticate] }, async (request) => {
    const userId = getUserId(request);
    const found = await db.query<{ config_json: Record<string, unknown> }>(
      "SELECT config_json FROM user_agent_configs WHERE user_id = $1 LIMIT 1",
      [userId]
    );

    return {
      config: found.rows[0]?.config_json ?? null
    };
  });

  fastify.put("/agents-config", { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = putAgentsConfigSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const userId = getUserId(request);
    const encoded = JSON.stringify(parsed.data.config);
    await db.query(
      `INSERT INTO user_agent_configs (user_id, config_json, updated_at)
       VALUES ($1, $2::jsonb, NOW())
       ON CONFLICT (user_id)
       DO UPDATE SET config_json = EXCLUDED.config_json, updated_at = NOW()`,
      [userId, encoded]
    );

    return { ok: true };
  });

  fastify.get("/conversations", { preHandler: [fastify.authenticate] }, async (request) => {
    const userId = getUserId(request);
    const found = await db.query<{ conversations_json: Array<Record<string, unknown>> }>(
      "SELECT conversations_json FROM user_conversations WHERE user_id = $1 LIMIT 1",
      [userId]
    );

    return {
      conversations: found.rows[0]?.conversations_json ?? []
    };
  });

  fastify.put("/conversations", { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = putConversationsSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const userId = getUserId(request);
    const encoded = JSON.stringify(parsed.data.conversations);
    await db.query(
      `INSERT INTO user_conversations (user_id, conversations_json, updated_at)
       VALUES ($1, $2::jsonb, NOW())
       ON CONFLICT (user_id)
       DO UPDATE SET conversations_json = EXCLUDED.conversations_json, updated_at = NOW()`,
      [userId, encoded]
    );

    return { ok: true };
  });

  fastify.post("/conversations/add", { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = addConversationSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const userId = getUserId(request);
    const encodedConversation = JSON.stringify(parsed.data.conversation);
    await db.query(
      `INSERT INTO user_conversations (user_id, conversations_json, updated_at)
       VALUES ($1, jsonb_build_array($2::jsonb), NOW())
       ON CONFLICT (user_id)
       DO UPDATE SET conversations_json = jsonb_build_array($2::jsonb) || user_conversations.conversations_json,
                     updated_at = NOW()`,
      [userId, encodedConversation]
    );

    return { ok: true };
  });
};
