import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";

import { config } from "../config";
import { db } from "../db";

// ── Types ──────────────────────────────────────────────────

interface GoogleTokenRow {
  user_id: string;
  access_token: string;
  refresh_token: string | null;
  token_expires_at: Date;
  scopes: string;
}

interface CalendarEvent {
  id: string;
  summary: string;
  description?: string;
  location?: string;
  start: { dateTime?: string; date?: string };
  end: { dateTime?: string; date?: string };
  htmlLink?: string;
}

interface GoogleCalendarListResponse {
  items?: CalendarEvent[];
}

// ── Helpers ────────────────────────────────────────────────

function getUserId(request: { user?: unknown }): string {
  const payload = request.user as { sub?: string } | undefined;
  const userId = payload?.sub?.trim() ?? "";
  if (!userId) throw new Error("Missing user id in JWT");
  return userId;
}

const CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.events";

async function getGoogleTokenRow(userId: string): Promise<GoogleTokenRow | null> {
  const result = await db.query<GoogleTokenRow>(
    "SELECT user_id, access_token, refresh_token, token_expires_at, scopes FROM user_google_tokens WHERE user_id = $1 LIMIT 1",
    [userId]
  );
  return result.rows[0] ?? null;
}

async function getValidAccessToken(userId: string): Promise<
  | { ok: true; accessToken: string }
  | { ok: false; reason: "no_tokens" | "no_calendar_scope" | "refresh_failed" }
> {
  const row = await getGoogleTokenRow(userId);

  if (!row) {
    return { ok: false, reason: "no_tokens" };
  }

  if (!row.scopes.includes(CALENDAR_SCOPE)) {
    return { ok: false, reason: "no_calendar_scope" };
  }

  // Check if token is still valid (60s buffer)
  const now = Date.now();
  const expiresAt = new Date(row.token_expires_at).getTime();

  if (now < expiresAt - 60_000) {
    return { ok: true, accessToken: row.access_token };
  }

  // Token expired — refresh it
  if (!row.refresh_token) {
    return { ok: false, reason: "refresh_failed" };
  }

  try {
    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: config.GOOGLE_CLIENT_ID!,
        client_secret: config.GOOGLE_CLIENT_SECRET!,
        refresh_token: row.refresh_token,
        grant_type: "refresh_token",
      }),
    });

    if (!response.ok) {
      return { ok: false, reason: "refresh_failed" };
    }

    const data = (await response.json()) as {
      access_token?: string;
      expires_in?: number;
      scope?: string;
    };

    if (!data.access_token || !data.expires_in) {
      return { ok: false, reason: "refresh_failed" };
    }

    const newExpiresAt = new Date(Date.now() + data.expires_in * 1000);

    await db.query(
      `UPDATE user_google_tokens
       SET access_token = $1, token_expires_at = $2, updated_at = NOW()
       WHERE user_id = $3`,
      [data.access_token, newExpiresAt, userId]
    );

    return { ok: true, accessToken: data.access_token };
  } catch {
    return { ok: false, reason: "refresh_failed" };
  }
}

// ── Zod Schemas ────────────────────────────────────────────

const getEventsSchema = z.object({
  date: z
    .string()
    .regex(/^\d{4}-\d{2}-\d{2}$/, "Expected YYYY-MM-DD format")
    .optional(),
});

const createEventSchema = z.object({
  title: z.string().min(1).max(500),
  description: z.string().max(5000).optional(),
  startDateTime: z.string(),
  endDateTime: z.string(),
  location: z.string().max(500).optional(),
});

// ── Routes ─────────────────────────────────────────────────

export const calendarRoutes: FastifyPluginAsync = async (fastify) => {
  // GET /status — Is Google Calendar connected?
  fastify.get("/status", { preHandler: [fastify.authenticate] }, async (request) => {
    const userId = getUserId(request);
    const row = await getGoogleTokenRow(userId);

    if (!row) {
      return { connected: false, reason: "no_google_account" };
    }

    if (!row.scopes.includes(CALENDAR_SCOPE)) {
      return { connected: false, reason: "missing_calendar_scope" };
    }

    return { connected: true };
  });

  // GET /events?date=YYYY-MM-DD — List events for a day
  fastify.get("/events", { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const userId = getUserId(request);

    const parsed = getEventsSchema.safeParse(request.query);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const tokenResult = await getValidAccessToken(userId);
    if (!tokenResult.ok) {
      return reply.code(403).send({
        error: "calendar_not_connected",
        reason: tokenResult.reason,
      });
    }

    const dateStr = parsed.data.date ?? new Date().toISOString().slice(0, 10);
    const timeMin = `${dateStr}T00:00:00Z`;
    const timeMax = `${dateStr}T23:59:59Z`;

    const params = new URLSearchParams({
      timeMin,
      timeMax,
      singleEvents: "true",
      orderBy: "startTime",
      maxResults: "50",
    });

    const response = await fetch(
      `https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`,
      { headers: { Authorization: `Bearer ${tokenResult.accessToken}` } }
    );

    if (!response.ok) {
      if (response.status === 401) {
        await db.query("DELETE FROM user_google_tokens WHERE user_id = $1", [userId]);
        return reply.code(403).send({
          error: "calendar_not_connected",
          reason: "refresh_failed",
        });
      }
      return reply.code(502).send({ error: "Google Calendar API request failed" });
    }

    const data = (await response.json()) as GoogleCalendarListResponse;

    return {
      date: dateStr,
      events: (data.items ?? []).map((event) => ({
        id: event.id,
        title: event.summary ?? "(Sin titulo)",
        description: event.description ?? null,
        location: event.location ?? null,
        startDateTime: event.start?.dateTime ?? event.start?.date ?? null,
        endDateTime: event.end?.dateTime ?? event.end?.date ?? null,
        htmlLink: event.htmlLink ?? null,
      })),
    };
  });

  // POST /events — Create a calendar event
  fastify.post("/events", { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const userId = getUserId(request);

    const parsed = createEventSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const tokenResult = await getValidAccessToken(userId);
    if (!tokenResult.ok) {
      return reply.code(403).send({
        error: "calendar_not_connected",
        reason: tokenResult.reason,
      });
    }

    const { title, description, startDateTime, endDateTime, location } = parsed.data;

    const eventBody: Record<string, unknown> = {
      summary: title,
      start: { dateTime: startDateTime },
      end: { dateTime: endDateTime },
    };
    if (description) eventBody.description = description;
    if (location) eventBody.location = location;

    const response = await fetch(
      "https://www.googleapis.com/calendar/v3/calendars/primary/events",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${tokenResult.accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(eventBody),
      }
    );

    if (!response.ok) {
      if (response.status === 401) {
        await db.query("DELETE FROM user_google_tokens WHERE user_id = $1", [userId]);
        return reply.code(403).send({
          error: "calendar_not_connected",
          reason: "refresh_failed",
        });
      }
      return reply.code(502).send({ error: "Failed to create Google Calendar event" });
    }

    const created = (await response.json()) as CalendarEvent;

    return {
      id: created.id,
      title: created.summary,
      startDateTime: created.start?.dateTime ?? null,
      endDateTime: created.end?.dateTime ?? null,
      htmlLink: created.htmlLink ?? null,
    };
  });
};
