import { z } from 'npm:zod@3';
import { initSentry } from '../_shared/sentry.ts';
import { CORS, json, parseBody, serveAuthed, serverError } from '../_shared/http.ts';
import { isRateLimited, RATE_LIMIT_WRITE, rateLimitResponse } from '../_shared/rate-limit.ts';
initSentry();

const SubmitBody = z.object({
  comparison_id: z.string().uuid(),
  winner_id: z.string().uuid(),
});

serveAuthed(async (req, _authHeader, supabase) => {
  if (await isRateLimited('submit-comparison', req, RATE_LIMIT_WRITE)) {
    return rateLimitResponse(CORS);
  }

  const parsed = await parseBody(req, SubmitBody);
  if (parsed instanceof Response) return parsed;

  const { comparison_id, winner_id } = parsed;

  // Single atomic transaction, and the only round trip this endpoint makes:
  // the RPC itself fetches the comparison row (RLS-scoped to the caller's
  // session), validates winner_id, computes loser_id, and writes both new
  // Elo ratings. It raises 'UE002' if the comparison doesn't exist, 'UE003'
  // if winner_id isn't one of the two compared photos, and 'UE001' if
  // completed_at was already set (preventing the TOCTOU race from the
  // original multi-step write approach).
  const { data, error: submitError } = await supabase.rpc(
    'submit_comparison_atomic',
    {
      p_comparison_id: comparison_id,
      p_winner_id: winner_id,
    },
  );

  const result = data?.[0];
  if (submitError || !result) {
    switch (submitError?.code) {
      case 'UE001':
        return json({ error: 'Comparison already submitted' }, 409);
      case 'UE002':
        return json({ error: 'Comparison not found' }, 404);
      case 'UE003':
        return json({ error: 'winner_id must be one of the two compared photos' }, 400);
      default:
        return await serverError(
          submitError ?? new Error('submit_comparison_atomic returned no row'),
          'Failed to record comparison result',
        );
    }
  }

  return json({
    winner_id,
    loser_id: result.loser_id,
    winner_new_rating: result.winner_new_rating,
    loser_new_rating: result.loser_new_rating,
  });
});
