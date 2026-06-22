import * as Sentry from "npm:@sentry/deno@8";

export function initSentry(): void {
  const dsn = Deno.env.get("SENTRY_DSN");
  if (!dsn) return;
  Sentry.init({ dsn, tracesSampleRate: 0 });
}

export { Sentry };
