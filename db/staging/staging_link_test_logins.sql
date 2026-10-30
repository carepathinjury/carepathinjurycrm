-- STAGING ONLY. Run after creating the test logins under Authentication > Users.
-- Links each login to a test staff member or a test partner account.
update public.users set auth_user_id = (select id from auth.users where email = 'manager@carepath-staging.example')     where email = 'manager@carepath-staging.example';
update public.users set auth_user_id = (select id from auth.users where email = 'coordinator@carepath-staging.example') where email = 'coordinator@carepath-staging.example';

insert into public.portal_users (id, email, full_name, title, role, firm_contact_id)
select id, email, 'Elena Ruiz', 'Senior Paralegal', 'firm_admin', 'ct_rk' from auth.users where email = 'kvoelker+firm@carepathinjury.com'
on conflict (id) do nothing;
insert into public.portal_users (id, email, full_name, title, organization, role)
select id, email, 'Dana Whitfield', 'Claims Adjuster', 'Commonwealth Casualty Co.', 'third_party' from auth.users where email = 'kvoelker+adjuster@carepathinjury.com'
on conflict (id) do nothing;

-- Check: should list 4 rows, each with a login id
select 'staff' as kind, name as who, auth_user_id is not null as linked from public.users where email in ('manager@carepath-staging.example','coordinator@carepath-staging.example')
union all
select 'partner', full_name, true from public.portal_users;
