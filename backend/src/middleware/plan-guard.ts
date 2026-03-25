import type { FastifyRequest, FastifyReply } from "fastify";
import { db } from "../db";
import { effectiveTier, tierIndex, type PlanTier } from "../utils/plan-limits";

/**
 * Fetches the user's plan fields from the DB.
 * Caches on request to avoid multiple queries per request.
 */
async function getUserPlan(request: FastifyRequest) {
  if ((request as any)._planCache) return (request as any)._planCache;

  const payload = request.user as { sub: string };
  const result = await db.query(
    `SELECT plan_tier, plan_expires_at,
      monthly_query_limit, monthly_query_used,
      voice_minutes_limit, voice_minutes_used,
      max_agents, max_documents
    FROM users WHERE id = $1 LIMIT 1`,
    [payload.sub]
  );

  if (!result.rowCount || !result.rows[0]) return null;

  const row = result.rows[0] as {
    plan_tier: string;
    plan_expires_at: Date | null;
    monthly_query_limit: number;
    monthly_query_used: number;
    voice_minutes_limit: number;
    voice_minutes_used: number;
    max_agents: number;
    max_documents: number;
  };

  const plan = {
    ...row,
    effectiveTier: effectiveTier(row.plan_tier, row.plan_expires_at),
  };

  (request as any)._planCache = plan;
  return plan;
}

/**
 * PreHandler: require the user to have at least `minTier`.
 */
export function requirePlan(minTier: PlanTier) {
  return async (request: FastifyRequest, reply: FastifyReply) => {
    const plan = await getUserPlan(request);
    if (!plan) {
      return reply.code(401).send({ error: "User not found" });
    }

    if (tierIndex(plan.effectiveTier) < tierIndex(minTier)) {
      return reply.code(403).send({
        error: "Plan upgrade required",
        requiredTier: minTier,
        currentTier: plan.effectiveTier,
      });
    }
  };
}

/**
 * PreHandler: check monthly query quota.
 */
export async function checkQueryQuota(request: FastifyRequest, reply: FastifyReply) {
  const plan = await getUserPlan(request);
  if (!plan) return reply.code(401).send({ error: "User not found" });

  if (plan.monthly_query_limit >= 0 && plan.monthly_query_used >= plan.monthly_query_limit) {
    return reply.code(429).send({
      error: "Monthly query limit reached",
      limit: plan.monthly_query_limit,
      used: plan.monthly_query_used,
    });
  }
}

/**
 * PreHandler: check voice minutes quota.
 */
export async function checkVoiceQuota(request: FastifyRequest, reply: FastifyReply) {
  const plan = await getUserPlan(request);
  if (!plan) return reply.code(401).send({ error: "User not found" });

  if (plan.voice_minutes_limit === 0) {
    return reply.code(403).send({
      error: "Voice not included in your plan",
      currentTier: plan.effectiveTier,
    });
  }

  if (plan.voice_minutes_limit > 0 && plan.voice_minutes_used >= plan.voice_minutes_limit) {
    return reply.code(429).send({
      error: "Monthly voice minutes limit reached",
      limit: plan.voice_minutes_limit,
      used: plan.voice_minutes_used,
    });
  }
}

/**
 * Increment usage counter after successful operation.
 */
export async function incrementQueryUsage(userId: string) {
  await db.query(
    `UPDATE users SET monthly_query_used = monthly_query_used + 1, updated_at = NOW() WHERE id = $1`,
    [userId]
  );
}

export async function incrementVoiceUsage(userId: string, minutes: number) {
  await db.query(
    `UPDATE users SET voice_minutes_used = voice_minutes_used + $1, updated_at = NOW() WHERE id = $2`,
    [minutes, userId]
  );
}

/**
 * Check agent limit for a user.
 */
export async function checkAgentLimit(request: FastifyRequest, reply: FastifyReply) {
  const plan = await getUserPlan(request);
  if (!plan) return reply.code(401).send({ error: "User not found" });

  if (plan.max_agents < 0) return; // unlimited

  const payload = request.user as { sub: string };
  const result = await db.query(
    `SELECT config_json FROM user_agent_configs WHERE user_id = $1`,
    [payload.sub]
  );

  if (result.rowCount && result.rows[0]) {
    const config = result.rows[0].config_json as { agents?: unknown[] };
    const agentCount = Array.isArray(config?.agents) ? config.agents.length : 0;
    if (agentCount >= plan.max_agents) {
      return reply.code(403).send({
        error: "Agent limit reached",
        limit: plan.max_agents,
        current: agentCount,
      });
    }
  }
}

/**
 * Check document limit for a user.
 */
export async function checkDocumentLimit(request: FastifyRequest, reply: FastifyReply) {
  const plan = await getUserPlan(request);
  if (!plan) return reply.code(401).send({ error: "User not found" });

  if (plan.max_documents < 0) return; // unlimited

  const payload = request.user as { sub: string };
  const result = await db.query(
    `SELECT COUNT(*)::int AS doc_count FROM user_documents WHERE user_id = $1`,
    [payload.sub]
  );

  const docCount = result.rows[0]?.doc_count ?? 0;
  if (docCount >= plan.max_documents) {
    return reply.code(403).send({
      error: "Document limit reached",
      limit: plan.max_documents,
      current: docCount,
    });
  }
}
