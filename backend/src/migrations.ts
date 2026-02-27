import type { Pool } from "pg";

const migrationStatements = [
  `CREATE EXTENSION IF NOT EXISTS "pgcrypto";`,
  `CREATE TABLE IF NOT EXISTS users (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      email TEXT NOT NULL UNIQUE,
      name TEXT,
      password_hash TEXT,
      email_verified_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE TABLE IF NOT EXISTS auth_sessions (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      refresh_token_hash TEXT NOT NULL UNIQUE,
      user_agent TEXT,
      ip_address INET,
      expires_at TIMESTAMPTZ NOT NULL,
      revoked_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_id ON auth_sessions(user_id);`,
  `CREATE INDEX IF NOT EXISTS idx_auth_sessions_expires_at ON auth_sessions(expires_at);`,
  `CREATE TABLE IF NOT EXISTS magic_links (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at TIMESTAMPTZ NOT NULL,
      consumed_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE INDEX IF NOT EXISTS idx_magic_links_user_id ON magic_links(user_id);`,
  `CREATE INDEX IF NOT EXISTS idx_magic_links_expires_at ON magic_links(expires_at);`,
  `CREATE TABLE IF NOT EXISTS user_agent_configs (
      user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      config_json JSONB NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE TABLE IF NOT EXISTS user_conversations (
      user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      conversations_json JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE TABLE IF NOT EXISTS user_documents (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      agent_id TEXT NOT NULL,
      file_name TEXT NOT NULL,
      file_type TEXT NOT NULL,
      chunk_count INTEGER NOT NULL DEFAULT 0,
      char_count INTEGER NOT NULL DEFAULT 0,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );`,
  `CREATE INDEX IF NOT EXISTS idx_user_documents_user_agent
     ON user_documents(user_id, agent_id);`
] as const;

export async function runMigrations(pool: Pool): Promise<void> {
  for (const statement of migrationStatements) {
    await pool.query(statement);
  }
}
