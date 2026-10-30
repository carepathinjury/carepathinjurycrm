-- =====================================================================
-- 001  PORTAL FOUNDATION  (add-only)
--
-- What it does
--   * Adds new columns to existing tables (all empty to start).
--   * Adds new tables for the partner portal.
--   * Adds the access rules for the NEW tables only.
--
-- What it does NOT do
--   * It does not delete, rename or change any existing column or row.
--   * It does not change how the current CRM works. The CRM keeps reading
--     and writing its tables exactly as it does today.
--
-- Safe to run on the live project ahead of launch. Runs as one transaction:
-- if any line fails, nothing is applied.
--
-- IMPORTANT: no partner accounts may be created on the live project until
-- 900_cutover_access_rules.sql has also been run. Until then the existing
-- CRM tables are still readable with the public key.
-- =====================================================================

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. NEW COLUMNS ON EXISTING TABLES
-- ---------------------------------------------------------------------

-- Staff: link each CRM user to a real login (Supabase Auth)
alter table public.users add column if not exists auth_user_id uuid unique;
alter table public.users add column if not exists active boolean not null default true;

-- Firm of record as a real link to the firm's Contacts entry.
-- The existing typed-in law_firm / attorney / law_contact fields stay as they are.
alter table public.cases     add column if not exists firm_contact_id text references public.contacts(id) on delete set null;
alter table public.referrals add column if not exists firm_contact_id text references public.contacts(id) on delete set null;
create index if not exists cases_firm_contact_idx     on public.cases(firm_contact_id);
create index if not exists referrals_firm_contact_idx on public.referrals(firm_contact_id);

-- Referrals submitted through the portal
alter table public.referrals add column if not exists submitted_via text;          -- 'portal' or null
alter table public.referrals add column if not exists portal_submitted_by uuid;    -- portal user who sent it

-- RXNT patient link (for the appointment feed)
alter table public.cases     add column if not exists rxnt_patient_id text;
alter table public.referrals add column if not exists rxnt_patient_id text;

-- ---------------------------------------------------------------------
-- 2. NEW TABLES
-- ---------------------------------------------------------------------

-- People outside CarePath who sign in to the portal
create table if not exists public.portal_users (
  id               uuid primary key references auth.users(id) on delete cascade,
  email            text not null unique,
  full_name        text not null,
  title            text,
  organization     text,                                   -- third parties (e.g. insurance carrier)
  role             text not null check (role in ('firm_admin','firm_user','third_party')),
  firm_contact_id  text references public.contacts(id) on delete set null,
  active           boolean not null default true,
  invited_by_staff integer references public.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  last_seen_at     timestamptz,
  constraint firm_users_need_firm check (role = 'third_party' or firm_contact_id is not null)
);

-- Individual sharing for third parties (adjusters, nurse case managers, ...)
create table if not exists public.access_grants (
  id               uuid primary key default gen_random_uuid(),
  case_id          text not null references public.cases(id) on delete cascade,
  user_id          uuid not null references public.portal_users(id) on delete cascade,
  scopes           text[] not null default '{appointments}',
                   -- any of: appointments, records, imaging, billing, messages, upload
  expires_at       timestamptz,
  revoked_at       timestamptz,
  granted_by_staff integer references public.users(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists access_grants_user_idx on public.access_grants(user_id);
create index if not exists access_grants_case_idx on public.access_grants(case_id);

-- Appointments (filled by the RXNT feed; manual entries allowed)
create table if not exists public.appointments (
  id              uuid primary key default gen_random_uuid(),
  case_id         text references public.cases(id) on delete cascade,
  referral_id     text references public.referrals(id) on delete cascade,
  rxnt_appt_id    text unique,
  rxnt_patient_id text,
  appt_at         timestamptz not null,
  location        text,
  provider        text,
  visit_type      text,
  status          text not null default 'scheduled'
                  check (status in ('scheduled','completed','no_show','cancelled','rescheduled')),
  portal_note     text,                                    -- only what is safe to show partners
  source          text not null default 'rxnt' check (source in ('rxnt','manual')),
  synced_at       timestamptz,
  created_at      timestamptz not null default now(),
  constraint appt_belongs_somewhere check (case_id is not null or referral_id is not null)
);
create index if not exists appointments_case_idx on public.appointments(case_id, appt_at);
create index if not exists appointments_ref_idx  on public.appointments(referral_id, appt_at);

-- Documents shared through the portal (files live in the private bucket)
create table if not exists public.portal_documents (
  id                  uuid primary key default gen_random_uuid(),
  case_id             text not null references public.cases(id) on delete cascade,
  category            text not null check (category in
                      ('medical_records','imaging','billing_ledger','narrative','external_upload','other')),
  title               text not null,
  storage_path        text not null unique,                -- '<case_id>/<uuid>-<filename>'
  service_from        date,
  service_to          date,
  file_size           bigint,
  mime_type           text,
  source              text not null check (source in ('carepath','external')),
  uploaded_by_staff   integer references public.users(id) on delete set null,
  uploaded_by_partner uuid references public.portal_users(id) on delete set null,
  created_at          timestamptz not null default now()
);
create index if not exists portal_documents_case_idx on public.portal_documents(case_id, created_at desc);

-- Shared case-coordination updates, messages and records requests.
-- Everything in this table is visible to the firm / grantee.
-- Internal notes stay where they are today (update_log, notes, task_log).
create table if not exists public.portal_messages (
  id              uuid primary key default gen_random_uuid(),
  case_id         text references public.cases(id) on delete cascade,
  referral_id     text references public.referrals(id) on delete cascade,
  author_staff    integer references public.users(id) on delete set null,
  author_partner  uuid references public.portal_users(id) on delete set null,
  kind            text not null default 'message' check (kind in ('update','message','records_request')),
  body            text not null check (length(body) between 1 and 5000),
  status          text not null default 'open' check (status in ('open','in_progress','fulfilled','closed')),
  created_at      timestamptz not null default now(),
  constraint msg_belongs_somewhere check (case_id is not null or referral_id is not null),
  constraint msg_has_one_author check ((author_staff is null) <> (author_partner is null))
);
create index if not exists portal_messages_case_idx on public.portal_messages(case_id, created_at);
create index if not exists portal_messages_ref_idx  on public.portal_messages(referral_id, created_at);

-- Every portal sign-in, view, download, upload and access change
create table if not exists public.portal_access_log (
  id            bigint generated always as identity primary key,
  actor_staff   integer references public.users(id) on delete set null,
  actor_partner uuid references public.portal_users(id) on delete set null,
  action        text not null,
  case_id       text,
  referral_id   text,
  document_id   uuid,
  detail        jsonb not null default '{}',
  at            timestamptz not null default now()
);
create index if not exists portal_access_log_at_idx on public.portal_access_log(at desc);

-- Remembered devices for partner sign-in (hash only; raw token stays in the browser)
create table if not exists public.trusted_devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.portal_users(id) on delete cascade,
  token_hash  text not null unique,
  label       text,
  verified_at timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '30 days',
  revoked_at  timestamptz
);
create table if not exists public.trusted_sessions (
  session_id uuid primary key,
  user_id    uuid not null references public.portal_users(id) on delete cascade,
  device_id  uuid references public.trusted_devices(id) on delete cascade,
  trusted_at timestamptz not null default now()
);

-- Reviewed mapping from typed-in firm names to Contacts entries
create table if not exists public.firm_name_matches (
  raw_name     text primary key,
  contact_id   text references public.contacts(id) on delete cascade,
  case_count   integer not null default 0,
  ref_count    integer not null default 0,
  status       text not null default 'suggested' check (status in ('suggested','approved','rejected')),
  reviewed_by  text,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

-- Partner session trusted? (email-code sign-in, or password sign-in on a remembered device)
create or replace function public.session_trusted() returns boolean
language sql stable security definer set search_path = public as $$
  select
    coalesce(exists (
      select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) m
      where m->>'method' in ('otp','magiclink','email/signup','invite')), false)
    or exists (
      select 1 from trusted_sessions ts
      join trusted_devices d on d.id = ts.device_id
      where ts.session_id = nullif(auth.jwt()->>'session_id','')::uuid
        and ts.user_id = auth.uid()
        and d.revoked_at is null and d.expires_at > now());
$$;

-- The CRM user (users.id) behind this login, if any
create or replace function public.current_staff_id() returns integer
language sql stable security definer set search_path = public as $$
  select id from users where auth_user_id = auth.uid() and active limit 1;
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.current_staff_id() is not null;
$$;

create or replace function public.staff_role() returns text
language sql stable security definer set search_path = public as $$
  select role from users where auth_user_id = auth.uid() and active limit 1;
$$;

-- Partner helpers
create or replace function public.my_partner_role() returns text
language sql stable security definer set search_path = public as $$
  select role from portal_users where id = auth.uid() and active;
$$;

create or replace function public.my_firm() returns text
language sql stable security definer set search_path = public as $$
  select pu.firm_contact_id from portal_users pu
  where pu.id = auth.uid() and pu.active and pu.role in ('firm_admin','firm_user')
    and public.session_trusted();
$$;

create or replace function public.doc_scope(p_category text) returns text
language sql immutable as $$
  select case p_category when 'imaging' then 'imaging' when 'billing_ledger' then 'billing' else 'records' end;
$$;

-- THE rule for cases. scope: summary | appointments | records | imaging | billing | messages | upload
create or replace function public.can_access_case(p_case text, p_scope text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_staff()
    or (public.session_trusted() and (
      exists (select 1 from cases c
              where c.id = p_case and c.firm_contact_id is not null
                and c.firm_contact_id = public.my_firm())
      or exists (select 1 from access_grants g
                 join portal_users u on u.id = g.user_id and u.active
                 where g.case_id = p_case and g.user_id = auth.uid()
                   and g.revoked_at is null
                   and (g.expires_at is null or g.expires_at > now())
                   and (p_scope = 'summary' or p_scope = any(g.scopes)))));
$$;

-- Referrals: staff, or the firm that sent / is attached to the referral
create or replace function public.can_access_referral(p_ref text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_staff()
    or exists (select 1 from referrals r
               where r.id = p_ref and r.firm_contact_id is not null
                 and r.firm_contact_id = public.my_firm());
$$;

-- CRM-style id: base-36 milliseconds + random, same shape as genId() in the CRM
create or replace function public.crm_gen_id() returns text
language plpgsql volatile as $$
declare ms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
        chars text := '0123456789abcdefghijklmnopqrstuvwxyz'; s text := ''; r text := '';
begin
  while ms > 0 loop s := substr(chars, (ms % 36)::int + 1, 1) || s; ms := ms / 36; end loop;
  for i in 1..6 loop r := r || substr(chars, floor(random()*36)::int + 1, 1); end loop;
  r := r || '_';
  for i in 1..3 loop r := r || substr(chars, floor(random()*36)::int + 1, 1); end loop;
  return s || '_' || r;
end $$;

-- ---------------------------------------------------------------------
-- 4. ACCESS RULES FOR THE NEW TABLES
-- ---------------------------------------------------------------------

alter table public.portal_users      enable row level security;
alter table public.access_grants     enable row level security;
alter table public.appointments      enable row level security;
alter table public.portal_documents  enable row level security;
alter table public.portal_messages   enable row level security;
alter table public.portal_access_log enable row level security;
alter table public.trusted_devices   enable row level security;
alter table public.trusted_sessions  enable row level security;
alter table public.firm_name_matches enable row level security;

drop policy if exists pu_read on public.portal_users;
create policy pu_read on public.portal_users for select using (
  id = auth.uid() or public.is_staff()
  or (public.session_trusted() and public.my_partner_role() = 'firm_admin'
      and firm_contact_id = public.my_firm()));
drop policy if exists pu_staff on public.portal_users;
create policy pu_staff on public.portal_users for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists ag_read on public.access_grants;
create policy ag_read on public.access_grants for select using (
  public.is_staff() or (public.session_trusted() and user_id = auth.uid()));
drop policy if exists ag_staff on public.access_grants;
create policy ag_staff on public.access_grants for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists ap_read on public.appointments;
create policy ap_read on public.appointments for select using (
  (case_id is not null and public.can_access_case(case_id, 'appointments'))
  or (referral_id is not null and public.can_access_referral(referral_id)));
drop policy if exists ap_staff on public.appointments;
create policy ap_staff on public.appointments for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists pd_read on public.portal_documents;
create policy pd_read on public.portal_documents for select using (
  public.can_access_case(case_id, public.doc_scope(category))
  or (source = 'external' and public.can_access_case(case_id, 'upload')));
drop policy if exists pd_partner_upload on public.portal_documents;
create policy pd_partner_upload on public.portal_documents for insert with check (
  source = 'external' and category = 'external_upload'
  and uploaded_by_partner = auth.uid() and uploaded_by_staff is null
  and public.can_access_case(case_id, 'upload'));
drop policy if exists pd_staff on public.portal_documents;
create policy pd_staff on public.portal_documents for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists pm_read on public.portal_messages;
create policy pm_read on public.portal_messages for select using (
  (case_id is not null and public.can_access_case(case_id, 'messages'))
  or (referral_id is not null and public.can_access_referral(referral_id)));
drop policy if exists pm_partner_write on public.portal_messages;
create policy pm_partner_write on public.portal_messages for insert with check (
  author_partner = auth.uid() and author_staff is null and kind in ('message','records_request')
  and ((case_id is not null and public.can_access_case(case_id, 'messages'))
       or (case_id is null and referral_id is not null and public.can_access_referral(referral_id))));
drop policy if exists pm_staff on public.portal_messages;
create policy pm_staff on public.portal_messages for all using (public.is_staff())
  with check (public.is_staff() and author_partner is null and author_staff = public.current_staff_id());

drop policy if exists log_staff_read on public.portal_access_log;
create policy log_staff_read on public.portal_access_log for select using (public.is_staff());

drop policy if exists td_read on public.trusted_devices;
create policy td_read on public.trusted_devices for select using (user_id = auth.uid() or public.is_staff());
drop policy if exists td_staff on public.trusted_devices;
create policy td_staff on public.trusted_devices for update using (public.is_staff()) with check (public.is_staff());

drop policy if exists fnm_staff on public.firm_name_matches;
create policy fnm_staff on public.firm_name_matches for all using (public.is_staff()) with check (public.is_staff());

-- Nobody signed out can touch the new tables at all
revoke all on public.portal_users, public.access_grants, public.appointments, public.portal_documents,
  public.portal_messages, public.portal_access_log, public.trusted_devices, public.trusted_sessions,
  public.firm_name_matches from anon;

-- ---------------------------------------------------------------------
-- 5. FUNCTIONS THE PORTAL CALLS
--    Partners never read CRM tables directly. These return only the
--    columns that are safe to show outside CarePath.
-- ---------------------------------------------------------------------

create or replace function public.log_event(p_action text, p_case text default null, p_referral text default null,
                                            p_document uuid default null, p_detail jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if p_case is not null and not public.can_access_case(p_case, 'summary') then raise exception 'not permitted'; end if;
  if p_referral is not null and not public.can_access_referral(p_referral) then raise exception 'not permitted'; end if;
  insert into portal_access_log(actor_staff, actor_partner, action, case_id, referral_id, document_id, detail)
  values (public.current_staff_id(),
          case when public.is_staff() then null else (select id from portal_users where id = auth.uid()) end,
          p_action, p_case, p_referral, p_document, coalesce(p_detail,'{}'));
  update portal_users set last_seen_at = now() where id = auth.uid();
end $$;

-- Cases the signed-in partner can see, with safe columns only
create or replace function public.portal_list_cases()
returns table (case_id text, patient_name text, dob date, doi date, case_type text, location text,
               status text, in_litigation boolean, firm_name text, next_appt timestamptz,
               last_visit timestamptz, scopes text[])
language sql stable security definer set search_path = public as $$
  select c.id, c.patient_name, c.dob, c.doi, c.case_type, c.location, c.status,
         coalesce(c.in_litigation,false), f.company,
         (select min(a.appt_at) from appointments a where a.case_id = c.id and a.status = 'scheduled' and a.appt_at >= now()),
         (select max(a.appt_at) from appointments a where a.case_id = c.id and a.status = 'completed'),
         case
           when public.is_staff() or (c.firm_contact_id is not null and c.firm_contact_id = public.my_firm())
             then array['appointments','records','imaging','billing','messages','upload']
           else (select coalesce(array_agg(distinct s), '{}') from access_grants g, unnest(g.scopes) s
                 where g.case_id = c.id and g.user_id = auth.uid() and g.revoked_at is null
                   and (g.expires_at is null or g.expires_at > now()))
         end
  from cases c
  left join contacts f on f.id = c.firm_contact_id
  where public.can_access_case(c.id, 'summary');
$$;

-- Referrals the signed-in firm has sent or is attached to (firm users only)
create or replace function public.portal_list_referrals()
returns table (referral_id text, patient_name text, dob date, doi date, case_type text, location text,
               status text, appt_date date, appt_outcome text, created_date date,
               submitted_via text, case_id text)
language sql stable security definer set search_path = public as $$
  select r.id, r.patient_name, r.dob, r.doi, r.case_type, r.location, r.status,
         r.appt_date, r.appt_outcome, r.created_date, r.submitted_via,
         (select c.id from cases c where c.source_ref_id = r.id limit 1)
  from referrals r
  where public.can_access_referral(r.id);
$$;

-- A firm sends CarePath a new referral. It lands in the CRM's referral queue
-- like any other referral; the CRM assigns it to a scheduler automatically.
create or replace function public.portal_submit_referral(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare me portal_users; firm contacts; new_id text := public.crm_gen_id();
        fname text := trim(coalesce(p->>'first_name','')); lname text := trim(coalesce(p->>'last_name',''));
begin
  select * into me from portal_users where id = auth.uid() and active;
  if me.id is null or me.role not in ('firm_admin','firm_user') or not public.session_trusted() then
    raise exception 'Only signed-in law firm users can send referrals';
  end if;
  if fname = '' or lname = '' then raise exception 'Patient first and last name are required'; end if;
  if coalesce(p->>'case_type','') not in ('WC','MVA','PI') then raise exception 'Case type must be WC, MVA or PI'; end if;
  select * into firm from contacts where id = me.firm_contact_id;

  insert into referrals (id, patient_name, first_name, last_name, dob, phone, email, doi, case_type, location,
                         language, attorney, law_firm, law_contact, referral_source, notes, status,
                         registered_by, created_date, entered_at, update_log,
                         firm_contact_id, submitted_via, portal_submitted_by)
  values (new_id, fname || ' ' || lname, fname, lname,
          nullif(p->>'dob','')::date, nullif(p->>'phone',''), nullif(p->>'email',''),
          nullif(p->>'doi','')::date, p->>'case_type', nullif(p->>'location',''),
          coalesce(nullif(p->>'language',''),'English'),
          nullif(p->>'attorney',''), firm.company, me.full_name || ' <' || me.email || '>',
          firm.company, nullif(p->>'notes',''), 'Pending Scheduling',
          'Partner Portal', current_date, now(), '[]'::jsonb,
          me.firm_contact_id, 'portal', me.id);

  perform public.log_event('submit_referral', null, new_id, null, jsonb_build_object('patient', fname || ' ' || lname));
  return new_id;
end $$;

-- Remembered devices (partners)
create or replace function public.register_device(p_token text, p_label text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from portal_users where id = auth.uid() and active) then raise exception 'not a portal user'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr','[]'::jsonb)) m
                 where m->>'method' in ('otp','magiclink','email/signup','invite')) then
    raise exception 'A device can only be remembered after an email-code sign-in';
  end if;
  insert into trusted_devices(user_id, token_hash, label)
  values (auth.uid(), encode(digest(p_token,'sha256'),'hex'), left(p_label,120))
  on conflict (token_hash) do update
    set verified_at = now(), expires_at = now() + interval '30 days', revoked_at = null
    where trusted_devices.user_id = auth.uid();
end $$;

create or replace function public.claim_device(p_token text)
returns boolean language plpgsql security definer set search_path = public as $$
declare d trusted_devices;
begin
  select * into d from trusted_devices
  where token_hash = encode(digest(coalesce(p_token,''),'sha256'),'hex')
    and user_id = auth.uid() and revoked_at is null and expires_at > now();
  if not found then return false; end if;
  insert into trusted_sessions(session_id, user_id, device_id)
  values (nullif(auth.jwt()->>'session_id','')::uuid, auth.uid(), d.id)
  on conflict (session_id) do nothing;
  return true;
end $$;

-- Staff: share / revoke
create or replace function public.grant_access(p_case text, p_user uuid, p_scopes text[], p_expires timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if not public.is_staff() then raise exception 'staff only'; end if;
  if exists (select 1 from unnest(p_scopes) s where s not in ('appointments','records','imaging','billing','messages','upload')) then
    raise exception 'unknown scope';
  end if;
  insert into access_grants(case_id, user_id, scopes, expires_at, granted_by_staff)
  values (p_case, p_user, p_scopes, p_expires, public.current_staff_id()) returning id into gid;
  perform public.log_event('grant', p_case, null, null, jsonb_build_object('user', p_user, 'scopes', p_scopes));
  return gid;
end $$;

create or replace function public.revoke_access(p_grant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare cid text;
begin
  if not public.is_staff() then raise exception 'staff only'; end if;
  update access_grants set revoked_at = now() where id = p_grant returning case_id into cid;
  perform public.log_event('revoke', cid, null, null, jsonb_build_object('grant', p_grant));
end $$;

-- Normalized firm name for matching: lower-case, punctuation removed, then
-- filler words removed ("Rosenthal and Kaye PC" = "Rosenthal & Kaye, P.C.")
create or replace function public.firm_key(p text) returns text
language sql immutable as $$
  select trim(regexp_replace(
           regexp_replace(
             regexp_replace(lower(coalesce(p,'')), '[^a-z0-9 ]', ' ', 'g'),
             '\m(the|and|law|firm|offices?|of|group|pc|p c|llc|llp|pllc|esq|associates)\M', ' ', 'g'),
           '\s+', ' ', 'g'));
$$;

-- Staff: suggest matches between typed-in firm names and Contacts law firms.
-- Writes only to firm_name_matches; nothing is linked until a person approves.
create or replace function public.portal_suggest_firm_matches() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_staff() and current_user not in ('postgres','service_role') then raise exception 'staff only'; end if;
  with norm as (
    select id, company,
           public.firm_key(company) as k
    from contacts where type = 'Law Firm' and coalesce(company,'') <> ''
  ), names as (
    select law_firm as raw, count(*) filter (where src='c') as cc, count(*) filter (where src='r') as rc
    from (select law_firm, 'c' src from cases where coalesce(trim(law_firm),'') <> ''
          union all select law_firm, 'r' from referrals where coalesce(trim(law_firm),'') <> '') x
    group by law_firm
  ), keyed as (
    select raw, cc, rc,
           public.firm_key(raw) as k
    from names
  )
  insert into firm_name_matches(raw_name, contact_id, case_count, ref_count, status)
  select k.raw, (select n.id from norm n where n.k = k.k and n.k <> '' order by n.company limit 1), k.cc, k.rc, 'suggested'
  from keyed k
  on conflict (raw_name) do update
    set case_count = excluded.case_count, ref_count = excluded.ref_count,
        contact_id = case when firm_name_matches.status = 'suggested' then excluded.contact_id else firm_name_matches.contact_id end;
  get diagnostics n = row_count;
  return n;
end $$;

-- Staff: link cases/referrals for APPROVED matches only. Only fills the new
-- firm_contact_id column where it is still empty; never overwrites.
create or replace function public.portal_apply_firm_matches() returns jsonb
language plpgsql security definer set search_path = public as $$
declare nc integer; nr integer;
begin
  if not public.is_staff() and current_user not in ('postgres','service_role') then raise exception 'staff only'; end if;
  update cases c set firm_contact_id = m.contact_id
  from firm_name_matches m
  where m.status = 'approved' and m.contact_id is not null and c.law_firm = m.raw_name and c.firm_contact_id is null;
  get diagnostics nc = row_count;
  update referrals r set firm_contact_id = m.contact_id
  from firm_name_matches m
  where m.status = 'approved' and m.contact_id is not null and r.law_firm = m.raw_name and r.firm_contact_id is null;
  get diagnostics nr = row_count;
  return jsonb_build_object('cases_linked', nc, 'referrals_linked', nr);
end $$;

-- Only signed-in users may call these
revoke all on function public.log_event(text,text,text,uuid,jsonb), public.portal_list_cases(),
  public.portal_list_referrals(), public.portal_submit_referral(jsonb), public.register_device(text,text),
  public.claim_device(text), public.grant_access(text,uuid,text[],timestamptz), public.revoke_access(uuid),
  public.portal_suggest_firm_matches(), public.portal_apply_firm_matches() from public, anon;
grant execute on function public.log_event(text,text,text,uuid,jsonb), public.portal_list_cases(),
  public.portal_list_referrals(), public.portal_submit_referral(jsonb), public.register_device(text,text),
  public.claim_device(text), public.grant_access(text,uuid,text[],timestamptz), public.revoke_access(uuid),
  public.portal_suggest_firm_matches(), public.portal_apply_firm_matches() to authenticated;

-- ---------------------------------------------------------------------
-- 6. FILE STORAGE (private bucket; files under '<case_id>/...')
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('portal-docs', 'portal-docs', false, 104857600)
on conflict (id) do nothing;

drop policy if exists portal_docs_read on storage.objects;
create policy portal_docs_read on storage.objects for select to authenticated using (
  bucket_id = 'portal-docs' and exists (
    select 1 from public.portal_documents d
    where d.storage_path = storage.objects.name
      and (public.can_access_case(d.case_id, public.doc_scope(d.category))
           or (d.source = 'external' and public.can_access_case(d.case_id, 'upload')))));

drop policy if exists portal_docs_upload on storage.objects;
create policy portal_docs_upload on storage.objects for insert to authenticated with check (
  bucket_id = 'portal-docs'
  and public.can_access_case((storage.foldername(name))[1], 'upload'));

drop policy if exists portal_docs_staff on storage.objects;
create policy portal_docs_staff on storage.objects for all to authenticated
  using (bucket_id = 'portal-docs' and public.is_staff())
  with check (bucket_id = 'portal-docs' and public.is_staff());

commit;
