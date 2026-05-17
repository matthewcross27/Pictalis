import { createClient } from 'jsr:@supabase/supabase-js@2';
import { z } from 'npm:zod@3';
import { updateElo } from '../_shared/elo.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const SubmitBody = z.object({
  comparison_id: z.string().uuid(),
  winner_id: z.string().uuid(),
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
      status: 401,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } }
  );

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const parsed = SubmitBody.safeParse(body);
  if (!parsed.success) {
    return new Response(JSON.stringify({ error: parsed.error.flatten() }), {
      status: 400,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { comparison_id, winner_id } = parsed.data;

  // RLS ensures this comparison belongs to the caller's session
  const { data: comparison, error: compError } = await supabase
    .from('comparisons')
    .select('id, photo_a_id, photo_b_id, completed_at')
    .eq('id', comparison_id)
    .single();

  if (compError || !comparison) {
    return new Response(JSON.stringify({ error: 'Comparison not found' }), {
      status: 404,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (comparison.completed_at != null) {
    return new Response(JSON.stringify({ error: 'Comparison already submitted' }), {
      status: 409,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (winner_id !== comparison.photo_a_id && winner_id !== comparison.photo_b_id) {
    return new Response(
      JSON.stringify({ error: 'winner_id must be one of the two compared photos' }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } }
    );
  }

  const loser_id =
    winner_id === comparison.photo_a_id ? comparison.photo_b_id : comparison.photo_a_id;

  const { data: photoPair, error: photoError } = await supabase
    .from('photos')
    .select('id, elo_rating, comparison_count')
    .in('id', [winner_id, loser_id]);

  if (photoError || !photoPair || photoPair.length !== 2) {
    return new Response(JSON.stringify({ error: 'Failed to fetch photo ratings' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const winner = photoPair.find((p) => p.id === winner_id)!;
  const loser = photoPair.find((p) => p.id === loser_id)!;
  const { winnerNew, loserNew } = updateElo(winner.elo_rating, loser.elo_rating);

  // Mark comparison complete first to prevent duplicate submissions
  const { error: compError2 } = await supabase
    .from('comparisons')
    .update({ winner_id, completed_at: new Date().toISOString() })
    .eq('id', comparison_id);

  if (compError2) {
    return new Response(JSON.stringify({ error: 'Failed to record comparison result' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Update Elo ratings after comparison is committed
  const [winnerUpdate, loserUpdate] = await Promise.all([
    supabase
      .from('photos')
      .update({ elo_rating: winnerNew, comparison_count: winner.comparison_count + 1 })
      .eq('id', winner_id),
    supabase
      .from('photos')
      .update({ elo_rating: loserNew, comparison_count: loser.comparison_count + 1 })
      .eq('id', loser_id),
  ]);

  if (winnerUpdate.error || loserUpdate.error) {
    return new Response(JSON.stringify({ error: 'Failed to update photo ratings' }), {
      status: 500,
      headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(
    JSON.stringify({ winner_id, loser_id, winner_new_rating: winnerNew, loser_new_rating: loserNew }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } }
  );
});
