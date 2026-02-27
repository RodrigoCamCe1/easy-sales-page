import { randomUUID } from "node:crypto";

import { QdrantClient } from "@qdrant/js-client-rest";

import { config } from "./config";

const COLLECTION_NAME = "agent_documents";
const VECTOR_SIZE = 1536; // text-embedding-3-small

let client: QdrantClient | null = null;

export function getQdrantClient(): QdrantClient {
  if (!client) {
    client = new QdrantClient({
      url: config.QDRANT_URL,
      apiKey: config.QDRANT_API_KEY,
    });
  }
  return client;
}

export async function ensureCollection(): Promise<void> {
  const qdrant = getQdrantClient();

  const collections = await qdrant.getCollections();
  const exists = collections.collections.some(
    (c) => c.name === COLLECTION_NAME
  );

  if (!exists) {
    await qdrant.createCollection(COLLECTION_NAME, {
      vectors: {
        size: VECTOR_SIZE,
        distance: "Cosine",
      },
    });

    // Create payload indexes for efficient filtering
    await qdrant.createPayloadIndex(COLLECTION_NAME, {
      field_name: "user_id",
      field_schema: "keyword",
    });
    await qdrant.createPayloadIndex(COLLECTION_NAME, {
      field_name: "agent_id",
      field_schema: "keyword",
    });
    await qdrant.createPayloadIndex(COLLECTION_NAME, {
      field_name: "file_id",
      field_schema: "keyword",
    });
  }
}

export interface ChunkWithVector {
  chunkText: string;
  vector: number[];
  chunkIndex: number;
}

export async function upsertChunks(
  userId: string,
  agentId: string,
  fileId: string,
  fileName: string,
  chunks: ChunkWithVector[]
): Promise<void> {
  if (chunks.length === 0) return;

  const qdrant = getQdrantClient();

  const points = chunks.map((chunk, i) => ({
    id: randomUUID(),
    payload: {
      user_id: userId,
      agent_id: agentId,
      file_id: fileId,
      file_name: fileName,
      chunk_index: chunk.chunkIndex,
      chunk_text: chunk.chunkText,
    },
    vector: chunk.vector,
  }));

  // Upsert in batches of 100
  for (let i = 0; i < points.length; i += 100) {
    const batch = points.slice(i, i + 100);
    await qdrant.upsert(COLLECTION_NAME, { points: batch });
  }
}

export async function deleteByFileId(
  userId: string,
  fileId: string
): Promise<void> {
  const qdrant = getQdrantClient();

  await qdrant.delete(COLLECTION_NAME, {
    filter: {
      must: [
        { key: "user_id", match: { value: userId } },
        { key: "file_id", match: { value: fileId } },
      ],
    },
  });
}

export async function searchRelevant(
  userId: string,
  agentId: string,
  queryVector: number[],
  limit: number = 5
): Promise<Array<{ text: string; score: number; fileName: string }>> {
  const qdrant = getQdrantClient();

  const results = await qdrant.query(COLLECTION_NAME, {
    query: queryVector,
    filter: {
      must: [
        { key: "user_id", match: { value: userId } },
        { key: "agent_id", match: { value: agentId } },
      ],
    },
    limit,
    with_payload: true,
  });

  return results.points.map((point) => ({
    text: (point.payload?.chunk_text as string) ?? "",
    score: point.score ?? 0,
    fileName: (point.payload?.file_name as string) ?? "",
  }));
}

export { COLLECTION_NAME };
