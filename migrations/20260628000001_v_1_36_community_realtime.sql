-- V1.36: Enable Supabase Realtime for community tables
--
-- community_posts gets REPLICA IDENTITY FULL so UPDATE events carry the complete
-- row. This is required because:
--   • Soft-deletes (deleted_at being set) arrive as UPDATE events — the handler
--     checks payload['deleted_at'] to know whether to remove the post from the list.
--   • Content edits also arrive as UPDATE events and the client needs the full
--     row to reconstruct the updated post in the feed.
--
-- community_poll_votes is added so vote totals eventually become subscribable
-- (clients currently trigger a full feed refresh on poll INSERT events, but
--  making this table realtime-ready avoids another migration later).
--
-- RLS policies on both tables are unchanged and continue to restrict which rows
-- each authenticated user can receive.

alter table app.community_posts replica identity full;

alter publication supabase_realtime add table app.community_posts;
alter publication supabase_realtime add table app.community_poll_votes;
