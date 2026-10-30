-- =====================================================================
-- 900 ROLLBACK  (emergency only)
--
-- Undoes 900_cutover_access_rules.sql so the CURRENT CRM (public-key
-- sign-in) works again. Use together with republishing the current CRM
-- version. No data is added, changed or deleted.
--
-- Portal tables keep their own access rules, so partner data stays
-- protected; disable partner sign-in while rolled back.
-- =====================================================================

begin;

do $$
declare t text;
begin
  foreach t in array array['activity_log','app_data','app_settings','call_log','callback_requests','cases',
    'contacts','daily_metrics','fax_log','marketing_contacts','marketing_initiatives','mkt_reports',
    'nj_mva_precerts','referrals','system_config','tickets','users','profiles']
  loop
    execute format('drop policy if exists staff_all on public.%I', t);
    execute format('alter table public.%I disable row level security', t);
    execute format('grant all on public.%I to anon, authenticated', t);
  end loop;
end $$;

grant usage, select on all sequences in schema public to anon, authenticated;

commit;
