import { z } from 'npm:zod@3';
import { updateElo } from '../_shared/elo.ts';
import { initSentry } from '../_shared/sentry.ts';
import { json, parseJsonBody, serveAuthed } from '../_shared/http.ts';
initSentry();

const SubmitBody = z.object({
  comparison_id: z.string().uuid(),
  winner_id: z.string().uuid(),
});

serveAuthed(async (req, _authHeader, supabase) => {
  const body = await parseJsonBody(req);
  if (body instanceof Response) return body;

  const parsed = SubmitBody.safeParse(body);
  if (!parsed.success) {
    return json({ error: parsed.error.flatten() }, 400);
  }

  const { comparison_id, winner_id } = parsed.data;

  // RLS ensures this comparison belongs to the caller's session
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .select('id, photo_a_id, photo_b_id')
    .eq('id', comparison_id)
    .single();

  if (compError || !comparison) {
    return json({ error: 'Comparison not found' }, 404);
  }

  if (
    winner_id !== comparison.photo_a_id && winner_id !== comparison.photo_b_id
  ) {
    return json({ error: 'winner_id must be one of the two compared photos' }, 400);
  }

  const loser_id = winner_id === comparison.photo_a_id
    ? comparison.photo_b_id
    : comparison.photo_a_id;

  const { data: photoPair, error: photoError } = await supabase
    .from('photos')
    .select('id, elo_rating, comparison_count')
    .in('id', [winner_id, loser_id]);

  if (photoError || !photoPair || photoPair.length !== 2) {
    return json({ error: 'Failed to fetch photo ratings' }, 500);
  }

  const winner = photoPair.find((p) => p.id === winner_id);
  const loser = photoPair.find((p) => p.id === loser_id);
  if (!winner || !loser) {
    return json({ error: 'Failed to fetch photo ratings' }, 500);
  }
  const { winnerNew, loserNew } = updateElo(
    winner.elo_rating,
    loser.elo_rating,
  );

  // Single atomic transaction: claim comparison + update both Elo ratings.
  // The RPC raises 'already_submitted' if completed_at was already set,
  // preventing the TOCTOU race from the previous multi-step write approach.
  const { error: submitError } = await supabase.rpc(
    'submit_comparison_atomic',
    {
      p_comparison_id: comparison_id,
      p_winner_id: winner_id,
      p_loser_id: loser_id,
      p_winner_new_rating: winnerNew,
      p_loser_new_rating: loserNew,
    },
  );

  if (submitError) {
    const isAlreadyDone = submitError.code === 'UE001';
    return json(
      {
        error: isAlreadyDone
          ? 'Comparison already submitted'
          : 'Failed to record comparison result',
      },
      isAlreadyDone ? 409 : 500,
    );
  }

  return json({
    winner_id,
    loser_id,
    winner_new_rating: winnerNew,
    loser_new_rating: loserNew,
  });
});
