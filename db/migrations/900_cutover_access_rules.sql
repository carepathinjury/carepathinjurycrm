-- =====================================================================
-- 900  CUTOVER ACCESS RULES  (launch day only)
--
-- Turns on database-level access rules for the 18 existing CRM tables.
-- After this runs, the database answers only to signed-in CarePath staff
-- (a login linked to an active row in users). The public key alone can
-- read nothing.
--
-- No data is added, changed or deleted.
--
-- RUN ONLY at cutover, at the same moment the new CRM (with real logins)
-- goes live. The current CRM signs in with the public key, so it stops
-- working the moment this runs. To undo: 900_rollback.sql.
--
-- Staff keep the same access they have today (every staff member can read
-- and write every CRM table). Narrowing by role is a later, separate step.
-- =====================================================================

begin;

do $$
declare t text;
begin
  foreach t in array array['activity_log','app_data','app_settings','call_log','callback_requests','cases',
    'contacts','daily_metrics','fax_log','marketing_contacts','marketing_initiatives','mkt_reports',
    'nj_mva_precerts','referrals','system_config','tickets','users','profiles']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists staff_all on public.%I', t);
    if t <> 'profiles' then   -- profiles is unused by the CRM; it stays locked
      execute format('create policy staff_all on public.%I for all to authenticated using (public.is_staff()) with check (public.is_staff())', t);
    end if;
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- Passwords: after cutover nobody reads the old password column through the API.
-- (The column itself is left in place; clearing it is a later step once every
-- staff member has signed in with their new login.)
revoke select, insert, update on public.users from authenticated;
grant select (id, name, email, role, avatar_color, avatar_initials, created_at, auth_user_id, active)
  on public.users to authenticated;
grant insert (name, email, password, role, avatar_color, avatar_initials, auth_user_id, active),
      update (name, email, role, avatar_color, avatar_initials, auth_user_id, active)
  on public.users to authenticated;

-- Sequences used by inserts
grant usage, select on all sequences in schema public to authenticated;

commit;
