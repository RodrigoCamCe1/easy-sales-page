import { config } from "../config";
import { db } from "../db";
import { generateOpaqueToken, hashOpaqueToken } from "./crypto";

export type UserRow = {
  id: string;
  email: string;
  name: string | null;
  password_hash: string | null;
  email_verified_at: Date | null;
};

export function buildSafeUser(user: UserRow): { id: string; email: string; name: string | null } {
  return {
    id: user.id,
    email: user.email,
    name: user.name
  };
}

export function extractRequestMeta(request: {
  ip: string;
  headers: Record<string, unknown>;
}): { ip: string; userAgent: string | null } {
  const rawUa = request.headers["user-agent"];
  const userAgent = typeof rawUa === "string" ? rawUa : null;
  return {
    ip: request.ip,
    userAgent
  };
}

export function calculateExpiry(days: number): Date {
  return new Date(Date.now() + days * 24 * 60 * 60 * 1000);
}

export async function issueSession(input: {
  fastify: { jwt: { sign: (payload: object, options: { expiresIn: string }) => string } };
  user: UserRow;
  ip: string;
  userAgent: string | null;
}): Promise<{
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresIn: string;
  refreshTokenExpiresAt: string;
}> {
  const refreshToken = generateOpaqueToken(48);
  const refreshTokenHash = hashOpaqueToken(refreshToken);
  const refreshExpiresAt = calculateExpiry(config.REFRESH_TOKEN_TTL_DAYS);

  await db.query(
    `INSERT INTO auth_sessions (user_id, refresh_token_hash, user_agent, ip_address, expires_at)
     VALUES ($1, $2, $3, $4, $5)`,
    [input.user.id, refreshTokenHash, input.userAgent, input.ip, refreshExpiresAt]
  );

  const accessToken = input.fastify.jwt.sign(
    {
      sub: input.user.id,
      email: input.user.email
    },
    { expiresIn: config.ACCESS_TOKEN_TTL }
  );

  return {
    accessToken,
    refreshToken,
    accessTokenExpiresIn: config.ACCESS_TOKEN_TTL,
    refreshTokenExpiresAt: refreshExpiresAt.toISOString()
  };
}
