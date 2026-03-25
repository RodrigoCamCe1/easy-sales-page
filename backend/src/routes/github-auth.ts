import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";

import { config } from "../config";
import { db } from "../db";
import {
  type UserRow,
  buildSafeUser,
  extractRequestMeta,
  issueSession,
} from "../utils/auth-helpers";
import { pendingStates, completedAuths } from "../utils/oauth-state-store";

const initSchema = z.object({
  state: z.string().uuid(),
});

const pollSchema = z.object({
  state: z.string().uuid(),
});

function successHtml(): string {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>AsesorIA</title>
<style>
  body { font-family: system-ui, sans-serif; background: #0B0C10; color: #fff;
         display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
  .card { text-align: center; padding: 40px; border-radius: 16px;
          background: #111827; border: 1px solid rgba(92,178,255,0.2); }
  h1 { color: #5CB2FF; }
</style></head>
<body><div class="card">
  <h1>Login exitoso!</h1>
  <p>Puedes cerrar esta ventana y volver a la aplicacion.</p>
</div></body></html>`;
}

function errorHtml(message: string): string {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>AsesorIA - Error</title>
<style>
  body { font-family: system-ui, sans-serif; background: #0B0C10; color: #fff;
         display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
  .card { text-align: center; padding: 40px; border-radius: 16px;
          background: #111827; border: 1px solid rgba(255,80,80,0.3); }
  h1 { color: #FF5050; }
</style></head>
<body><div class="card">
  <h1>Error</h1>
  <p>${message}</p>
</div></body></html>`;
}

export const githubAuthRoutes: FastifyPluginAsync = async (fastify) => {
  // ─── POST /init ────────────────────────────────────────────
  fastify.post("/init", async (request, reply) => {
    if (!config.GITHUB_CLIENT_ID || !config.GITHUB_CLIENT_SECRET) {
      return reply.code(501).send({ error: "GitHub OAuth not configured" });
    }

    const parsed = initSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { state } = parsed.data;
    pendingStates.set(state, true);

    const redirectUri = `${config.BACKEND_PUBLIC_URL}/api/auth/github/callback`;

    const params = new URLSearchParams({
      client_id: config.GITHUB_CLIENT_ID,
      redirect_uri: redirectUri,
      state,
      scope: "user:email",
    });

    const consentUrl = `https://github.com/login/oauth/authorize?${params.toString()}`;

    return reply.send({ consentUrl });
  });

  // ─── GET /callback ─────────────────────────────────────────
  fastify.get("/callback", async (request, reply) => {
    const { code, state, error } = request.query as Record<string, string>;

    if (error) {
      return reply.type("text/html").send(errorHtml("Autenticacion cancelada."));
    }

    if (!state || !code) {
      return reply.type("text/html").send(errorHtml("Parametros invalidos."));
    }

    if (!pendingStates.has(state)) {
      return reply.type("text/html").send(errorHtml("Estado de sesion expirado o invalido."));
    }
    pendingStates.delete(state);

    // Exchange code for access_token
    const redirectUri = `${config.BACKEND_PUBLIC_URL}/api/auth/github/callback`;

    let accessToken: string;
    try {
      const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify({
          client_id: config.GITHUB_CLIENT_ID!,
          client_secret: config.GITHUB_CLIENT_SECRET!,
          code,
          redirect_uri: redirectUri,
        }),
      });

      if (!tokenResponse.ok) {
        return reply.type("text/html").send(
          errorHtml("Error al intercambiar el codigo con GitHub.")
        );
      }

      const tokenData = (await tokenResponse.json()) as Record<string, unknown>;

      if (tokenData.error) {
        return reply.type("text/html").send(
          errorHtml(`GitHub error: ${tokenData.error_description || tokenData.error}`)
        );
      }

      accessToken = tokenData.access_token as string;
      if (!accessToken) {
        return reply.type("text/html").send(errorHtml("GitHub no devolvio un access token."));
      }
    } catch {
      return reply.type("text/html").send(
        errorHtml("No se pudo conectar con GitHub.")
      );
    }

    // Fetch user profile
    let name: string | null = null;
    let githubEmail: string | null = null;

    try {
      const userResponse = await fetch("https://api.github.com/user", {
        headers: {
          Authorization: `Bearer ${accessToken}`,
          Accept: "application/json",
          "User-Agent": "AsesorIA-Backend",
        },
      });

      if (!userResponse.ok) {
        return reply.type("text/html").send(errorHtml("No se pudo obtener perfil de GitHub."));
      }

      const userData = (await userResponse.json()) as Record<string, unknown>;
      name = (userData.name as string | undefined) ?? (userData.login as string | undefined) ?? null;
      githubEmail = ((userData.email as string | undefined) ?? "").toLowerCase().trim() || null;
    } catch {
      return reply.type("text/html").send(errorHtml("No se pudo conectar con GitHub API."));
    }

    // If email is private, fetch from /user/emails
    if (!githubEmail) {
      try {
        const emailsResponse = await fetch("https://api.github.com/user/emails", {
          headers: {
            Authorization: `Bearer ${accessToken}`,
            Accept: "application/json",
            "User-Agent": "AsesorIA-Backend",
          },
        });

        if (!emailsResponse.ok) {
          return reply.type("text/html").send(errorHtml("No se pudo obtener email de GitHub."));
        }

        const emails = (await emailsResponse.json()) as Array<{
          email: string;
          primary: boolean;
          verified: boolean;
        }>;

        const primary = emails.find((e) => e.primary && e.verified);
        const verified = primary ?? emails.find((e) => e.verified);
        const fallback = verified ?? emails[0];

        if (fallback) {
          githubEmail = fallback.email.toLowerCase().trim();
        }
      } catch {
        return reply.type("text/html").send(errorHtml("No se pudo obtener email de GitHub."));
      }
    }

    if (!githubEmail) {
      return reply.type("text/html").send(errorHtml("GitHub no proporciono un email."));
    }

    const email = githubEmail;

    // Find or create user
    const existing = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = $1 LIMIT 1",
      [email]
    );

    let user: UserRow;
    if (existing.rowCount && existing.rows[0]) {
      user = existing.rows[0];
      if (!user.name && name) {
        await db.query(
          "UPDATE users SET name = $1, updated_at = NOW() WHERE id = $2",
          [name, user.id]
        );
        user = { ...user, name };
      }
      if (!user.email_verified_at) {
        await db.query(
          "UPDATE users SET email_verified_at = NOW(), updated_at = NOW() WHERE id = $1",
          [user.id]
        );
      }
    } else {
      const inserted = await db.query<UserRow>(
        `INSERT INTO users (email, name, email_verified_at)
         VALUES ($1, $2, NOW())
         RETURNING id, email, name, password_hash, email_verified_at`,
        [email, name]
      );
      user = inserted.rows[0];
    }

    // Issue session
    const { ip, userAgent } = extractRequestMeta(request);
    const session = await issueSession({ fastify, user, ip, userAgent });

    // Store for poll endpoint
    completedAuths.set(state, {
      ...session,
      user: buildSafeUser(user),
    });

    return reply.type("text/html").send(successHtml());
  });

  // ─── GET /poll ─────────────────────────────────────────────
  fastify.get("/poll", async (request, reply) => {
    const parsed = pollSchema.safeParse(request.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { state } = parsed.data;

    const result = completedAuths.get(state);
    if (!result) {
      return reply.send({ status: "pending" });
    }

    // One-time consumption
    completedAuths.delete(state);

    return reply.send({
      status: "completed",
      ...result,
    });
  });
};
