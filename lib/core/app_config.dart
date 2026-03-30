import 'dart:io';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;

import '../services/audio_preferences_store.dart';

const String appVersion = '1.5.0';
const String githubRepo = 'RodrigoCamCe1/easy-sales-page';
const double barHeight = 280.0;
const String dartDefineOpenAIKey = String.fromEnvironment('OPENAI_API_KEY');
const String defaultOpenAIRealtimeModel = 'gpt-4o-mini-realtime-preview';
const bool showFfmpegLogs = false;
const bool showOpenAIEvents = false;
const String promptFileName = 'prompt.txt';
const int defaultVadSilenceMs = 1000;
const int defaultRealtimeFlushSeconds = 6;

String get openAIKey {
  if (dartDefineOpenAIKey.isNotEmpty) {
    return dartDefineOpenAIKey;
  }
  if (dotenv.isInitialized) {
    return dotenv.env['OPENAI_API_KEY'] ?? '';
  }
  return '';
}

String get openAIRealtimeModel =>
    dotenv.env['OPENAI_REALTIME_MODEL'] ?? defaultOpenAIRealtimeModel;

String get systemPrompt =>
    dotenv.env['SYSTEM_PROMPT'] ?? 'Eres un agente de IA que responde de forma clara y breve.';

String get windowsMicDevice => AudioPreferencesStore.instance.micDeviceId;
String get windowsAudioSampleRate =>
    dotenv.env['WINDOWS_AUDIO_SAMPLE_RATE'] ?? '';

String get promptFilePath => p.join(Directory.current.path, promptFileName);
File get promptFile => File(promptFilePath);

int _readIntEnv(String key, int fallback) {
  final raw = dotenv.env[key];
  if (raw == null || raw.trim().isEmpty) return fallback;
  final parsed = int.tryParse(raw.trim());
  return parsed ?? fallback;
}

int get vadSilenceMs => _readIntEnv('OPENAI_VAD_SILENCE_MS', defaultVadSilenceMs);
int get realtimeFlushSeconds =>
    _readIntEnv('OPENAI_REALTIME_FLUSH_SECONDS', defaultRealtimeFlushSeconds);

String get backendApiBaseUrl =>
    (dotenv.env['BACKEND_API_URL'] ?? 'https://api.easyexpert.top').trim();

// ── Groq STT Pipeline ──────────────────────────────────────────────────────
/// When true, system audio uses Groq Whisper + GPT-4o-mini instead of OpenAI Realtime.
bool get useGroqPipeline {
  final val = dotenv.env['USE_GROQ_PIPELINE'] ?? 'false';
  return val.trim().toLowerCase() == 'true';
}

String get groqApiKey => dotenv.env['GROQ_API_KEY'] ?? '';

String get groqModel => dotenv.env['GROQ_MODEL'] ?? 'whisper-large-v3-turbo';

String get chatCompletionModel => dotenv.env['CHAT_COMPLETION_MODEL'] ?? 'gpt-4o-mini';
