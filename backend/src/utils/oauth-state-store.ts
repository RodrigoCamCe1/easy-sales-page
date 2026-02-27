interface StoreEntry<T> {
  data: T;
  expiresAt: number;
}

class OAuthStateStore<T = unknown> {
  private store = new Map<string, StoreEntry<T>>();
  private cleanupInterval: ReturnType<typeof setInterval>;

  constructor(private ttlMs: number = 5 * 60 * 1000) {
    this.cleanupInterval = setInterval(() => this.sweep(), 60_000);
  }

  set(key: string, data: T): void {
    this.store.set(key, {
      data,
      expiresAt: Date.now() + this.ttlMs,
    });
  }

  get(key: string): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiresAt) {
      this.store.delete(key);
      return undefined;
    }
    return entry.data;
  }

  has(key: string): boolean {
    return this.get(key) !== undefined;
  }

  delete(key: string): void {
    this.store.delete(key);
  }

  private sweep(): void {
    const now = Date.now();
    for (const [key, entry] of this.store) {
      if (now > entry.expiresAt) {
        this.store.delete(key);
      }
    }
  }

  destroy(): void {
    clearInterval(this.cleanupInterval);
    this.store.clear();
  }
}

export type OAuthResult = {
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresIn: string;
  refreshTokenExpiresAt: string;
  user: { id: string; email: string; name: string | null };
};

export const pendingStates = new OAuthStateStore<true>(5 * 60 * 1000);
export const completedAuths = new OAuthStateStore<OAuthResult>(5 * 60 * 1000);
