/** Plan tier hierarchy and default limits per tier. */

export const PLAN_TIERS = ['free', 'pro', 'business'] as const;
export type PlanTier = (typeof PLAN_TIERS)[number];

export interface PlanLimits {
  monthlyQueryLimit: number;   // text queries per month
  voiceSessions: number;       // -1 = unlimited, otherwise total sessions
  voiceSessionMaxMin: number;  // max minutes per session (-1 = unlimited)
  maxAgents: number;           // -1 = unlimited
  maxDocuments: number;        // -1 = unlimited
  historyDays: number;         // -1 = unlimited
  transcriptions: boolean;
  suggestedQuestions: boolean;
  maxUsers: number;            // seats included
}

export const TIER_LIMITS: Record<PlanTier, PlanLimits> = {
  free: {
    monthlyQueryLimit: 30,
    voiceSessions: 5,
    voiceSessionMaxMin: 15,
    maxAgents: 1,
    maxDocuments: 1,
    historyDays: 7,
    transcriptions: false,
    suggestedQuestions: false,
    maxUsers: 1,
  },
  pro: {
    monthlyQueryLimit: 500,
    voiceSessions: -1,
    voiceSessionMaxMin: 30,
    maxAgents: 5,
    maxDocuments: 50,
    historyDays: -1,
    transcriptions: true,
    suggestedQuestions: true,
    maxUsers: 5,
  },
  business: {
    monthlyQueryLimit: 2000,
    voiceSessions: -1,
    voiceSessionMaxMin: -1,
    maxAgents: -1,
    maxDocuments: 200,
    historyDays: -1,
    transcriptions: true,
    suggestedQuestions: true,
    maxUsers: 10,
  },
};

export function isValidTier(tier: string): tier is PlanTier {
  return PLAN_TIERS.includes(tier as PlanTier);
}

export function tierIndex(tier: string): number {
  return PLAN_TIERS.indexOf(tier as PlanTier);
}

/** Returns the effective tier considering expiration. */
export function effectiveTier(tier: string, expiresAt: Date | null): PlanTier {
  if (tier === 'free') return 'free';
  if (expiresAt && new Date() > expiresAt) return 'free';
  return isValidTier(tier) ? tier : 'free';
}

/** Build a plan summary object for API responses. */
export function buildPlanResponse(user: {
  plan_tier: string;
  plan_expires_at: Date | null;
  plan_activated_at: Date | null;
  monthly_query_limit: number;
  monthly_query_used: number;
  monthly_query_reset_at: Date | null;
  voice_minutes_limit: number;
  voice_minutes_used: number;
  max_agents: number;
  max_documents: number;
}) {
  const tier = effectiveTier(user.plan_tier, user.plan_expires_at);
  const isExpired = user.plan_tier !== 'free' && tier === 'free';
  const limits = TIER_LIMITS[tier];

  return {
    tier,
    isExpired,
    expiresAt: user.plan_expires_at,
    activatedAt: user.plan_activated_at,
    queryLimit: isExpired ? limits.monthlyQueryLimit : user.monthly_query_limit,
    queryUsed: user.monthly_query_used,
    queryResetAt: user.monthly_query_reset_at,
    voiceMinutesLimit: isExpired ? limits.voiceSessionMaxMin : user.voice_minutes_limit,
    voiceMinutesUsed: user.voice_minutes_used,
    voiceSessions: limits.voiceSessions,
    voiceSessionMaxMin: limits.voiceSessionMaxMin,
    maxAgents: isExpired ? limits.maxAgents : user.max_agents,
    maxDocuments: isExpired ? limits.maxDocuments : user.max_documents,
    historyDays: limits.historyDays,
    transcriptions: limits.transcriptions,
    suggestedQuestions: limits.suggestedQuestions,
    maxUsers: limits.maxUsers,
  };
}
