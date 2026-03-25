import type { FastifyInstance } from "fastify";
import { config } from "../config";
import { db } from "../db";
import { TIER_LIMITS, isValidTier, type PlanTier } from "../utils/plan-limits";

function getAdminEmails(): string[] {
  return config.ADMIN_EMAILS.split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
}

function isAdmin(email: string): boolean {
  return getAdminEmails().includes(email.toLowerCase());
}

export async function adminRoutes(fastify: FastifyInstance) {
  // All admin routes require auth + admin check
  fastify.addHook("preHandler", async (request, reply) => {
    try {
      await request.jwtVerify();
    } catch {
      return reply.code(401).send({ error: "Unauthorized" });
    }

    const payload = request.user as { sub: string; email: string };
    if (!isAdmin(payload.email)) {
      return reply.code(403).send({ error: "Forbidden: admin access required" });
    }
  });

  // ── POST /activate ──
  fastify.post("/activate", async (request, reply) => {
    const { email, plan_tier, duration_days } = request.body as {
      email: string;
      plan_tier: string;
      duration_days: number;
    };

    if (!email || !plan_tier || !duration_days) {
      return reply.code(400).send({ error: "email, plan_tier, and duration_days are required" });
    }
    if (!isValidTier(plan_tier)) {
      return reply.code(400).send({ error: `Invalid tier: ${plan_tier}` });
    }
    if (duration_days < 1 || duration_days > 3650) {
      return reply.code(400).send({ error: "duration_days must be between 1 and 3650" });
    }

    const limits = TIER_LIMITS[plan_tier as PlanTier];
    const adminPayload = request.user as { email: string };

    const result = await db.query(
      `UPDATE users SET
        plan_tier = $1,
        plan_expires_at = NOW() + ($2 || ' days')::interval,
        plan_activated_at = NOW(),
        plan_activated_by = $3,
        monthly_query_limit = $4,
        monthly_query_used = 0,
        monthly_query_reset_at = date_trunc('month', NOW()) + interval '1 month',
        voice_minutes_limit = $5,
        voice_minutes_used = 0,
        max_agents = $6,
        max_documents = $7,
        updated_at = NOW()
      WHERE LOWER(email) = LOWER($8)
      RETURNING id, email, name, plan_tier, plan_expires_at, plan_activated_at`,
      [
        plan_tier,
        String(duration_days),
        adminPayload.email,
        limits.monthlyQueryLimit,
        limits.voiceSessionMaxMin,
        limits.maxAgents,
        limits.maxDocuments,
        email,
      ]
    );

    if (result.rowCount === 0) {
      return reply.code(404).send({ error: "User not found" });
    }

    return reply.send({ user: result.rows[0] });
  });

  // ── POST /deactivate ──
  fastify.post("/deactivate", async (request, reply) => {
    const { email } = request.body as { email: string };
    if (!email) return reply.code(400).send({ error: "email is required" });

    const limits = TIER_LIMITS.free;

    const result = await db.query(
      `UPDATE users SET
        plan_tier = 'free',
        plan_expires_at = NULL,
        plan_activated_at = NULL,
        plan_activated_by = NULL,
        monthly_query_limit = $1,
        monthly_query_used = 0,
        voice_minutes_limit = $2,
        voice_minutes_used = 0,
        max_agents = $3,
        max_documents = $4,
        updated_at = NOW()
      WHERE LOWER(email) = LOWER($5)
      RETURNING id, email, name, plan_tier`,
      [limits.monthlyQueryLimit, limits.voiceSessionMaxMin, limits.maxAgents, limits.maxDocuments, email]
    );

    if (result.rowCount === 0) {
      return reply.code(404).send({ error: "User not found" });
    }

    return reply.send({ user: result.rows[0] });
  });

  // ── POST /extend ──
  fastify.post("/extend", async (request, reply) => {
    const { email, extra_days } = request.body as { email: string; extra_days: number };
    if (!email || !extra_days) {
      return reply.code(400).send({ error: "email and extra_days are required" });
    }

    const result = await db.query(
      `UPDATE users SET
        plan_expires_at = GREATEST(plan_expires_at, NOW()) + ($1 || ' days')::interval,
        updated_at = NOW()
      WHERE LOWER(email) = LOWER($2) AND plan_tier != 'free'
      RETURNING id, email, name, plan_tier, plan_expires_at`,
      [String(extra_days), email]
    );

    if (result.rowCount === 0) {
      return reply.code(404).send({ error: "User not found or is on free plan" });
    }

    return reply.send({ user: result.rows[0] });
  });

  // ── GET /users ──
  fastify.get("/users", async (request, reply) => {
    const { search, plan } = request.query as { search?: string; plan?: string };

    let query = `SELECT id, email, name, plan_tier, plan_expires_at, plan_activated_at,
      monthly_query_limit, monthly_query_used, voice_minutes_limit, voice_minutes_used,
      max_agents, max_documents, created_at
      FROM users WHERE 1=1`;
    const params: string[] = [];

    if (search) {
      params.push(`%${search}%`);
      query += ` AND (LOWER(email) LIKE LOWER($${params.length}) OR LOWER(name) LIKE LOWER($${params.length}))`;
    }
    if (plan) {
      params.push(plan);
      query += ` AND plan_tier = $${params.length}`;
    }

    query += ` ORDER BY created_at DESC LIMIT 100`;

    const result = await db.query(query, params);
    return reply.send({ users: result.rows });
  });
}
