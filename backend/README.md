# EasySales Backend (Phase 1)

Node + Fastify backend for user auth with PostgreSQL.

## What is included

- User registration with email and password
- Login with email and password
- Login with magic link (email-based)
- JWT access tokens
- Rotating refresh tokens with server-side sessions
- `GET /api/auth/me` protected endpoint
- Automatic DB bootstrap on server startup
- Docker Compose with Postgres + MailHog

## Stack

- Node 20
- TypeScript
- Fastify
- PostgreSQL
- Docker / Docker Compose

## Quick start (Docker)

1. Create env file:

```bash
cp .env.example .env
```

2. Update `JWT_SECRET` in `.env` to a strong value (32+ chars).

3. Run:

```bash
docker compose up --build
```

4. Check health:

```bash
curl http://localhost:4000/api/health
```

5. MailHog UI (magic link emails):

- http://localhost:8025

## Local run (without Docker)

1. Start Postgres and set `DATABASE_URL` in `.env`.
2. Install deps:

```bash
npm install
```

3. Run dev server:

```bash
npm run dev
```

## API endpoints (Phase 1)

- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/refresh`
- `POST /api/auth/logout`
- `POST /api/auth/magic-link/request`
- `POST /api/auth/magic-link/verify`
- `GET /api/auth/me` (Bearer token required)

## Example requests

Register:

```bash
curl -X POST http://localhost:4000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"ana@example.com","password":"supersecure123","name":"Ana"}'
```

Login:

```bash
curl -X POST http://localhost:4000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"ana@example.com","password":"supersecure123"}'
```

Request magic link:

```bash
curl -X POST http://localhost:4000/api/auth/magic-link/request \
  -H "Content-Type: application/json" \
  -d '{"email":"ana@example.com"}'
```

In non-production mode, response includes `devMagicLink` for fast testing.

## Notes

- This phase is auth-only. Agent and conversation persistence are phase 2.
- `refreshToken` is stored hashed in DB.
- Magic-link tokens are one-time and expire by `MAGIC_LINK_TTL_MINUTES`.
