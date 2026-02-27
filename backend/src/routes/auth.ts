import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";

import { config } from "../config";
import { db } from "../db";
import { generateOpaqueToken, hashOpaqueToken } from "../utils/crypto";
import { hashPassword, verifyPassword } from "../utils/password";
import {
  type UserRow,
  buildSafeUser,
  extractRequestMeta,
  issueSession,
} from "../utils/auth-helpers";

const registerSchema = z.object({
  email: z.email().transform((value) => value.toLowerCase().trim()),
  password: z.string().min(8, "Password must be at least 8 characters"),
  name: z.string().trim().min(1).max(120).optional()
});

const loginSchema = z.object({
  email: z.email().transform((value) => value.toLowerCase().trim()),
  password: z.string().min(1)
});

const refreshSchema = z.object({
  refreshToken: z.string().min(10)
});

const magicRequestSchema = z.object({
  email: z.email().transform((value) => value.toLowerCase().trim())
});

const magicVerifySchema = z.object({
  token: z.string().min(10)
});

const logoutSchema = z.object({
  refreshToken: z.string().min(10)
});

function calculateMagicExpiry(minutes: number): Date {
  return new Date(Date.now() + minutes * 60 * 1000);
}

export const authRoutes: FastifyPluginAsync = async (fastify) => {
  fastify.post("/register", async (request, reply) => {
    const parsed = registerSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { email, password, name } = parsed.data;

    const existing = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = $1 LIMIT 1",
      [email]
    );

    let user: UserRow;

    if (existing.rowCount && existing.rows[0]) {
      if (existing.rows[0].password_hash) {
        return reply.code(409).send({
          error: "Email is already registered"
        });
      }

      const nextHash = await hashPassword(password);
      const updated = await db.query<UserRow>(
        `UPDATE users
         SET password_hash = $2, name = COALESCE($3, name), updated_at = NOW()
         WHERE id = $1
         RETURNING id, email, name, password_hash, email_verified_at`,
        [existing.rows[0].id, nextHash, name ?? null]
      );
      user = updated.rows[0];
    } else {
      const passwordHash = await hashPassword(password);
      const inserted = await db.query<UserRow>(
        `INSERT INTO users (email, name, password_hash, email_verified_at)
         VALUES ($1, $2, $3, NOW())
         RETURNING id, email, name, password_hash, email_verified_at`,
        [email, name ?? null, passwordHash]
      );
      user = inserted.rows[0];
    }

    const { ip, userAgent } = extractRequestMeta(request);
    const session = await issueSession({
      fastify,
      user,
      ip,
      userAgent
    });

    return reply.code(201).send({
      user: buildSafeUser(user),
      ...session
    });
  });

  fastify.post("/login", async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { email, password } = parsed.data;

    const found = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = $1 LIMIT 1",
      [email]
    );

    if (!found.rowCount || !found.rows[0]?.password_hash) {
      return reply.code(401).send({ error: "Invalid credentials" });
    }

    const user = found.rows[0];
    const passwordHash = user.password_hash;
    if (!passwordHash) {
      return reply.code(401).send({ error: "Invalid credentials" });
    }

    const matches = await verifyPassword(password, passwordHash);
    if (!matches) {
      return reply.code(401).send({ error: "Invalid credentials" });
    }

    const { ip, userAgent } = extractRequestMeta(request);
    const session = await issueSession({
      fastify,
      user,
      ip,
      userAgent
    });

    return reply.send({
      user: buildSafeUser(user),
      ...session
    });
  });

  fastify.post("/refresh", async (request, reply) => {
    const parsed = refreshSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const refreshTokenHash = hashOpaqueToken(parsed.data.refreshToken);

    const found = await db.query<UserRow & { session_id: string }>(
      `SELECT s.id AS session_id, u.id, u.email, u.name, u.password_hash, u.email_verified_at
       FROM auth_sessions s
       INNER JOIN users u ON u.id = s.user_id
       WHERE s.refresh_token_hash = $1
         AND s.revoked_at IS NULL
         AND s.expires_at > NOW()
       LIMIT 1`,
      [refreshTokenHash]
    );

    if (!found.rowCount || !found.rows[0]) {
      return reply.code(401).send({ error: "Invalid refresh token" });
    }

    await db.query(
      "UPDATE auth_sessions SET revoked_at = NOW() WHERE id = $1",
      [found.rows[0].session_id]
    );

    const { ip, userAgent } = extractRequestMeta(request);
    const session = await issueSession({
      fastify,
      user: found.rows[0],
      ip,
      userAgent
    });

    return reply.send({
      user: buildSafeUser(found.rows[0]),
      ...session
    });
  });

  fastify.post("/logout", async (request, reply) => {
    const parsed = logoutSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const refreshTokenHash = hashOpaqueToken(parsed.data.refreshToken);

    await db.query(
      `UPDATE auth_sessions
       SET revoked_at = NOW()
       WHERE refresh_token_hash = $1
         AND revoked_at IS NULL`,
      [refreshTokenHash]
    );

    return reply.code(204).send();
  });

  fastify.post("/magic-link/request", async (request, reply) => {
    const parsed = magicRequestSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const email = parsed.data.email;

    const found = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = $1 LIMIT 1",
      [email]
    );

    let user: UserRow;
    if (!found.rowCount || !found.rows[0]) {
      const inserted = await db.query<UserRow>(
        `INSERT INTO users (email, name)
         VALUES ($1, $2)
         RETURNING id, email, name, password_hash, email_verified_at`,
        [email, null]
      );
      user = inserted.rows[0];
    } else {
      user = found.rows[0];
    }

    const token = generateOpaqueToken(40);
    const tokenHash = hashOpaqueToken(token);
    const expiresAt = calculateMagicExpiry(config.MAGIC_LINK_TTL_MINUTES);

    await db.query(
      `INSERT INTO magic_links (user_id, token_hash, expires_at)
       VALUES ($1, $2, $3)`,
      [user.id, tokenHash, expiresAt]
    );

    const magicLink = `${config.MAGIC_LINK_BASE_URL}?token=${encodeURIComponent(token)}`;
    await fastify.mailer.sendMagicLink({
      to: email,
      magicLink,
      expiresMinutes: config.MAGIC_LINK_TTL_MINUTES
    });

    return reply.send({
      ok: true,
      message: "If the email exists, a sign-in link was sent.",
      ...(fastify.mailer.isProduction() ? {} : { devMagicLink: magicLink })
    });
  });

  fastify.post("/magic-link/verify", async (request, reply) => {
    const parsed = magicVerifySchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const tokenHash = hashOpaqueToken(parsed.data.token);

    const found = await db.query<UserRow & { magic_link_id: string }>(
      `SELECT ml.id AS magic_link_id, u.id, u.email, u.name, u.password_hash, u.email_verified_at
       FROM magic_links ml
       INNER JOIN users u ON u.id = ml.user_id
       WHERE ml.token_hash = $1
         AND ml.consumed_at IS NULL
         AND ml.expires_at > NOW()
       LIMIT 1`,
      [tokenHash]
    );

    if (!found.rowCount || !found.rows[0]) {
      return reply.code(401).send({ error: "Invalid or expired token" });
    }

    await db.query(
      `UPDATE magic_links
       SET consumed_at = NOW()
       WHERE id = $1`,
      [found.rows[0].magic_link_id]
    );

    await db.query(
      `UPDATE users
       SET email_verified_at = COALESCE(email_verified_at, NOW()), updated_at = NOW()
       WHERE id = $1`,
      [found.rows[0].id]
    );

    const { ip, userAgent } = extractRequestMeta(request);
    const session = await issueSession({
      fastify,
      user: found.rows[0],
      ip,
      userAgent
    });

    return reply.send({
      user: buildSafeUser(found.rows[0]),
      ...session
    });
  });

  fastify.get("/me", { preHandler: [fastify.authenticate] }, async (request) => {
    const payload = request.user as { sub: string; email: string };
    const found = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE id = $1 LIMIT 1",
      [payload.sub]
    );

    if (!found.rowCount || !found.rows[0]) {
      return { user: null };
    }

    return { user: buildSafeUser(found.rows[0]) };
  });
};
