import mammoth from "mammoth";
import pdfParse from "pdf-parse";
import OpenAI from "openai";

import { config } from "../config";

// ~500 tokens ≈ 2000 chars, overlap ~100 tokens ≈ 400 chars
const CHUNK_SIZE_CHARS = 2000;
const CHUNK_OVERLAP_CHARS = 400;
const MAX_FILE_CHARS = 200_000; // ~50K tokens
const EMBEDDING_BATCH_SIZE = 20;

let openaiClient: OpenAI | null = null;

function getOpenAI(): OpenAI {
  if (!openaiClient) {
    openaiClient = new OpenAI({ apiKey: config.OPENAI_API_KEY });
  }
  return openaiClient;
}

// ─── Text extraction ────────────────────────────────────────────

export async function extractText(
  buffer: Buffer,
  fileType: string
): Promise<string> {
  const type = fileType.toLowerCase().trim();

  if (type === "pdf") {
    const data = await pdfParse(buffer);
    return data.text ?? "";
  }

  if (type === "txt") {
    return buffer.toString("utf-8");
  }

  if (type === "docx") {
    const result = await mammoth.extractRawText({ buffer });
    return result.value ?? "";
  }

  throw new Error(`Unsupported file type: ${fileType}`);
}

// ─── Chunking ───────────────────────────────────────────────────

export function chunkText(text: string): string[] {
  const cleaned = text.replace(/\r\n/g, "\n").trim();
  if (cleaned.length === 0) return [];

  // Truncate if too long
  const source = cleaned.length > MAX_FILE_CHARS
    ? cleaned.slice(0, MAX_FILE_CHARS)
    : cleaned;

  // Split by paragraphs first
  const paragraphs = source.split(/\n{2,}/);
  const chunks: string[] = [];
  let current = "";

  for (const para of paragraphs) {
    const trimmed = para.trim();
    if (trimmed.length === 0) continue;

    if (current.length + trimmed.length + 1 <= CHUNK_SIZE_CHARS) {
      current += (current.length > 0 ? "\n\n" : "") + trimmed;
    } else {
      // Current chunk is big enough, push it
      if (current.length > 0) {
        chunks.push(current);
        // Overlap: take last CHUNK_OVERLAP_CHARS from current
        const overlapStart = Math.max(0, current.length - CHUNK_OVERLAP_CHARS);
        current = current.slice(overlapStart).trim();
      }

      // If paragraph itself is too large, split by sentences
      if (trimmed.length > CHUNK_SIZE_CHARS) {
        const sentences = trimmed.split(/(?<=[.!?])\s+/);
        for (const sentence of sentences) {
          if (current.length + sentence.length + 1 <= CHUNK_SIZE_CHARS) {
            current += (current.length > 0 ? " " : "") + sentence;
          } else {
            if (current.length > 0) {
              chunks.push(current);
              const overlapStart = Math.max(0, current.length - CHUNK_OVERLAP_CHARS);
              current = current.slice(overlapStart).trim();
            }
            // If sentence itself is huge, force-split by chars
            if (sentence.length > CHUNK_SIZE_CHARS) {
              for (let i = 0; i < sentence.length; i += CHUNK_SIZE_CHARS - CHUNK_OVERLAP_CHARS) {
                chunks.push(sentence.slice(i, i + CHUNK_SIZE_CHARS));
              }
              current = "";
            } else {
              current = sentence;
            }
          }
        }
      } else {
        current += (current.length > 0 ? "\n\n" : "") + trimmed;
      }
    }
  }

  if (current.trim().length > 0) {
    chunks.push(current.trim());
  }

  return chunks;
}

// ─── Embedding ──────────────────────────────────────────────────

export interface ChunkEmbedding {
  chunkText: string;
  chunkIndex: number;
  vector: number[];
}

export async function embedChunks(chunks: string[]): Promise<ChunkEmbedding[]> {
  if (chunks.length === 0) return [];

  const openai = getOpenAI();
  const results: ChunkEmbedding[] = [];

  for (let i = 0; i < chunks.length; i += EMBEDDING_BATCH_SIZE) {
    const batch = chunks.slice(i, i + EMBEDDING_BATCH_SIZE);

    const response = await openai.embeddings.create({
      model: config.OPENAI_EMBEDDING_MODEL,
      input: batch,
    });

    for (let j = 0; j < response.data.length; j++) {
      results.push({
        chunkText: batch[j],
        chunkIndex: i + j,
        vector: response.data[j].embedding,
      });
    }
  }

  return results;
}

export async function embedQuery(query: string): Promise<number[]> {
  const openai = getOpenAI();

  const response = await openai.embeddings.create({
    model: config.OPENAI_EMBEDDING_MODEL,
    input: query,
  });

  return response.data[0].embedding;
}

export function detectFileType(fileName: string): string | null {
  const ext = fileName.split(".").pop()?.toLowerCase() ?? "";
  if (ext === "pdf") return "pdf";
  if (ext === "txt") return "txt";
  if (ext === "docx") return "docx";
  return null;
}
