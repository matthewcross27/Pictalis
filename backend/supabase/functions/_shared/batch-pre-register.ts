import { z } from 'npm:zod@3';

export const BatchPreRegisterBody = z.object({
  session_id: z.string().uuid(),
  photo_ids: z.array(z.string().uuid()).min(1).max(300),
});
