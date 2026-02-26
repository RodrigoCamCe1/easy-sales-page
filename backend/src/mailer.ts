import nodemailer, { type Transporter } from "nodemailer";

import type { AppConfig } from "./config";

export class Mailer {
  private transporter: Transporter | null;
  private readonly from: string;
  private readonly nodeEnv: string;

  constructor(cfg: AppConfig) {
    this.from = cfg.SMTP_FROM;
    this.nodeEnv = cfg.NODE_ENV;

    if (cfg.SMTP_HOST && cfg.SMTP_PORT) {
      this.transporter = nodemailer.createTransport({
        host: cfg.SMTP_HOST,
        port: cfg.SMTP_PORT,
        secure: cfg.SMTP_SECURE,
        auth: cfg.SMTP_USER ? { user: cfg.SMTP_USER, pass: cfg.SMTP_PASS ?? "" } : undefined
      });
      return;
    }

    this.transporter = null;
  }

  async sendMagicLink(input: {
    to: string;
    magicLink: string;
    expiresMinutes: number;
  }): Promise<void> {
    const subject = "Your EasySales login link";
    const text = [
      "Use this link to sign in to EasySales:",
      input.magicLink,
      "",
      `This link expires in ${input.expiresMinutes} minutes.`
    ].join("\n");

    if (!this.transporter) {
      // eslint-disable-next-line no-console
      console.log(`[MAILER:DEV] To=${input.to} Subject="${subject}" Link=${input.magicLink}`);
      return;
    }

    await this.transporter.sendMail({
      from: this.from,
      to: input.to,
      subject,
      text
    });
  }

  isProduction(): boolean {
    return this.nodeEnv === "production";
  }
}
