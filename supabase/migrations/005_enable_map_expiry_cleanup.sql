begin;

-- The public map calls this idempotent cleanup before loading seat statuses.
-- It can only expire holds whose server-side deadline has already passed.
revoke all on function public.expire_stale_reservations() from public;
grant execute on function public.expire_stale_reservations() to anon, authenticated;

commit;
