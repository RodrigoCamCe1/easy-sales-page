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

export const googleAuthRoutes: FastifyPluginAsync = async (fastify) => {
  // ─── POST /init ────────────────────────────────────────────
  fastify.post("/init", async (request, reply) => {
    if (!config.GOOGLE_CLIENT_ID || !config.GOOGLE_CLIENT_SECRET) {
      return reply.code(501).send({ error: "Google OAuth not configured" });
    }

    const parsed = initSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { state } = parsed.data;
    pendingStates.set(state, true);

    const redirectUri = `${config.BACKEND_PUBLIC_URL}/api/auth/google/callback`;

    const params = new URLSearchParams({
      client_id: config.GOOGLE_CLIENT_ID,
      redirect_uri: redirectUri,
      response_type: "code",
      scope: "openid email profile",
      state,
      access_type: "offline",
      prompt: "select_account",
    });

    const consentUrl = `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;

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

    // Exchange code for tokens with Google
    const redirectUri = `${config.BACKEND_PUBLIC_URL}/api/auth/google/callback`;

    let tokenData: Record<string, unknown>;
    try {
      const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          code,
          client_id: config.GOOGLE_CLIENT_ID!,
          client_secret: config.GOOGLE_CLIENT_SECRET!,
          redirect_uri: redirectUri,
          grant_type: "authorization_code",
        }),
      });

      if (!tokenResponse.ok) {
        return reply.type("text/html").send(
          errorHtml("Error al intercambiar el codigo con Google.")
        );
      }

      tokenData = (await tokenResponse.json()) as Record<string, unknown>;
    } catch {
      return reply.type("text/html").send(
        errorHtml("No se pudo conectar con Google.")
      );
    }

    const idToken = tokenData.id_token as string | undefined;
    if (!idToken) {
      return reply.type("text/html").send(errorHtml("Google no devolvio un ID token."));
    }

    // Decode JWT payload (safe — token comes directly from Google via HTTPS + client_secret)
    let payload: Record<string, unknown>;
    try {
      payload = JSON.parse(
        Buffer.from(idToken.split(".")[1], "base64url").toString("utf8")
      );
    } catch {
      return reply.type("text/html").send(errorHtml("ID token invalido."));
    }

    const email = ((payload.email as string) ?? "").toLowerCase().trim();
    if (!email) {
      return reply.type("text/html").send(errorHtml("Google no proporciono un email."));
    }

    const name = (payload.name as string | undefined) ?? null;
    const emailVerified = payload.email_verified === true;

    // Find or create user
    const existing = await db.query<UserRow>(
      "SELECT id, email, name, password_hash, email_verified_at FROM users WHERE email = $1 LIMIT 1",
      [email]
    );

    let user: UserRow;
    if (existing.rowCount && existing.rows[0]) {
      user = existing.rows[0];
      // Update name if missing and Google provides one
      if (!user.name && name) {
        await db.query(
          "UPDATE users SET name = $1, updated_at = NOW() WHERE id = $2",
          [name, user.id]
        );
        user = { ...user, name };
      }
      // Mark email verified if not yet
      if (emailVerified && !user.email_verified_at) {
        await db.query(
          "UPDATE users SET email_verified_at = NOW(), updated_at = NOW() WHERE id = $1",
          [user.id]
        );
      }
    } else {
      const inserted = await db.query<UserRow>(
        `INSERT INTO users (email, name, email_verified_at)
         VALUES ($1, $2, $3)
         RETURNING id, email, name, password_hash, email_verified_at`,
        [email, name, emailVerified ? new Date() : null]
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
