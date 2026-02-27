import type { FastifyPluginAsync } from "fastify";
import { z } from "zod";

import { db } from "../db";
import {
  upsertChunks,
  deleteByFileId,
  searchRelevant,
} from "../qdrant";
import {
  extractText,
  chunkText,
  embedChunks,
  embedQuery,
  detectFileType,
} from "../services/document-processor";

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 MB

function getUserId(request: { user?: unknown }): string {
  const payload = request.user as { sub?: string } | undefined;
  const userId = payload?.sub?.trim() ?? "";
  if (!userId) {
    throw new Error("Missing user id in JWT");
  }
  return userId;
}

const searchSchema = z.object({
  agentId: z.string().min(1),
  query: z.string().min(1),
  limit: z.coerce.number().int().min(1).max(20).default(5),
});

export const documentRoutes: FastifyPluginAsync = async (fastify) => {
  // ─── Upload document ────────────────────────────────────────

  fastify.post(
    "/upload",
    { preHandler: [fastify.authenticate] },
    async (request, reply) => {
      const userId = getUserId(request);

      const data = await request.file();
      if (!data) {
        return reply.code(400).send({ error: "No file uploaded" });
      }

      const agentId = (
        (data.fields.agentId as { value?: string } | undefined)?.value ?? ""
      ).trim();
      if (!agentId) {
        return reply.code(400).send({ error: "agentId is required" });
      }

      const fileName = data.filename ?? "unknown";
      const fileType = detectFileType(fileName);
      if (!fileType) {
        return reply
          .code(400)
          .send({ error: "Unsupported file type. Use PDF, TXT, or DOCX." });
      }

      // Read file buffer
      const chunks: Buffer[] = [];
      let totalSize = 0;
      for await (const chunk of data.file) {
        totalSize += chunk.length;
        if (totalSize > MAX_FILE_SIZE) {
          return reply
            .code(400)
            .send({ error: "File too large. Maximum 10 MB." });
        }
        chunks.push(chunk);
      }
      const buffer = Buffer.concat(chunks);

      // Extract text
      let rawText: string;
      try {
        rawText = await extractText(buffer, fileType);
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        return reply
          .code(422)
          .send({ error: `Could not extract text: ${msg}` });
      }

      if (rawText.trim().length === 0) {
        return reply
          .code(422)
          .send({ error: "No text could be extracted from the file." });
      }

      // Chunk text
      const textChunks = chunkText(rawText);
      if (textChunks.length === 0) {
        return reply.code(422).send({ error: "No usable text chunks." });
      }

      // Embed chunks
      let embeddedChunks;
      try {
        embeddedChunks = await embedChunks(textChunks);
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        return reply
          .code(500)
          .send({ error: `Embedding failed: ${msg}` });
      }

      // Store metadata in PostgreSQL
      const insertResult = await db.query<{ id: string }>(
        `INSERT INTO user_documents (user_id, agent_id, file_name, file_type, chunk_count, char_count)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id`,
        [
          userId,
          agentId,
          fileName,
          fileType,
          embeddedChunks.length,
          rawText.length,
        ]
      );

      const fileId = insertResult.rows[0].id;

      // Store vectors in Qdrant
      await upsertChunks(
        userId,
        agentId,
        fileId,
        fileName,
        embeddedChunks.map((c) => ({
          chunkText: c.chunkText,
          vector: c.vector,
          chunkIndex: c.chunkIndex,
        }))
      );

      return {
        id: fileId,
        fileName,
        fileType,
        chunkCount: embeddedChunks.length,
        charCount: rawText.length,
      };
    }
  );

  // ─── List documents for agent ───────────────────────────────

  fastify.get(
    "/",
    { preHandler: [fastify.authenticate] },
    async (request) => {
      const userId = getUserId(request);
      const agentId = (
        (request.query as { agentId?: string }).agentId ?? ""
      ).trim();

      if (!agentId) {
        return { files: [] };
      }

      const result = await db.query<{
        id: string;
        file_name: string;
        file_type: string;
        chunk_count: number;
        char_count: number;
        created_at: string;
      }>(
        `SELECT id, file_name, file_type, chunk_count, char_count, created_at
         FROM user_documents
         WHERE user_id = $1 AND agent_id = $2
         ORDER BY created_at DESC`,
        [userId, agentId]
      );

      return {
        files: result.rows.map((row) => ({
          id: row.id,
          fileName: row.file_name,
          fileType: row.file_type,
          chunkCount: row.chunk_count,
          charCount: row.char_count,
          createdAt: row.created_at,
        })),
      };
    }
  );

  // ─── Delete document ────────────────────────────────────────

  fastify.delete(
    "/:fileId",
    { preHandler: [fastify.authenticate] },
    async (request, reply) => {
      const userId = getUserId(request);
      const { fileId } = request.params as { fileId: string };

      if (!fileId?.trim()) {
        return reply.code(400).send({ error: "fileId is required" });
      }

      // Verify ownership
      const found = await db.query(
        "SELECT id FROM user_documents WHERE id = $1 AND user_id = $2",
        [fileId, userId]
      );

      if (found.rows.length === 0) {
        return reply.code(404).send({ error: "Document not found" });
      }

      // Delete from Qdrant
      await deleteByFileId(userId, fileId);

      // Delete from PostgreSQL
      await db.query("DELETE FROM user_documents WHERE id = $1", [fileId]);

      return { ok: true };
    }
  );

  // ─── Search documents (RAG) ─────────────────────────────────

  fastify.post(
    "/search",
    { preHandler: [fastify.authenticate] },
    async (request, reply) => {
      const userId = getUserId(request);

      const parsed = searchSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: parsed.error.flatten() });
      }

      const { agentId, query, limit } = parsed.data;

      // Check if agent has any documents
      const docCount = await db.query<{ count: string }>(
        "SELECT COUNT(*) as count FROM user_documents WHERE user_id = $1 AND agent_id = $2",
        [userId, agentId]
      );

      if (parseInt(docCount.rows[0].count) === 0) {
        return { chunks: [] };
      }

      // Embed query
      let queryVector: number[];
      try {
        queryVector = await embedQuery(query);
      } catch (err) {
        const msg = err instanceof Error ? err.message : "Unknown error";
        return reply
          .code(500)
          .send({ error: `Query embedding failed: ${msg}` });
      }

      // Search Qdrant
      const results = await searchRelevant(userId, agentId, queryVector, limit);

      return {
        chunks: results.map((r) => ({
          text: r.text,
          score: r.score,
          fileName: r.fileName,
        })),
      };
    }
  );
};
