#!/bin/bash
set -e
H=/home/claude/.pgtest; P="psql -h $H -p 54329 -U postgres -v ON_ERROR_STOP=1 -q"
$P -c "drop database if exists stg" -c "create database stg"
D="$P -d stg"
$D -f test/supabase_stubs.sql
$D -f sql/00_staging_baseline_crm_tables.sql
echo "== add-only check: snapshot original columns, run 001, compare"
# put some rows in CRM tables first (what live looks like before 001)
$D -c "insert into contacts(id,type,company) values ('c1','Law Firm','Smith Law'); insert into cases(id,patient_name,law_firm) values ('k1','Jane Roe','Smith Law, PC'); insert into referrals(id,patient_name) values ('r1','Jane Roe'); insert into users(name,email,password,role) values ('A','a@x','pw','manager');"
SNAP="select md5(string_agg(t::text, '|' order by t::text)) from (select id,patient_name,law_firm,status,updated_at from cases union all select id,patient_name,law_firm,status,updated_at from referrals union all select id,company,type,email,null::timestamptz from contacts union all select id::text,name,email,password,null::timestamptz from users) t"
B=$($D -tAc "$SNAP"); CNT_B=$($D -tAc "select (select count(*) from cases)||','||(select count(*) from referrals)||','||(select count(*) from contacts)||','||(select count(*) from users)")
$D -f sql/001_portal_foundation.sql
$D -f sql/001_portal_foundation.sql   # second run must also succeed (safe to re-run)
A=$($D -tAc "$SNAP"); CNT_A=$($D -tAc "select (select count(*) from cases)||','||(select count(*) from referrals)||','||(select count(*) from contacts)||','||(select count(*) from users)")
[ "$A" = "$B" ] && [ "$CNT_A" = "$CNT_B" ] && echo "PASS existing data unchanged ($CNT_A rows; checksum $A)" || { echo "FAIL data changed"; exit 1; }
$D -c "delete from cases; delete from referrals; delete from contacts; delete from users;"
echo "== seed fake data"; $D -f sql/99_staging_fake_data.sql
echo "== cutover rules"; $D -f sql/900_cutover_access_rules.sql

# test identities
$D <<'SQL'
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-000000000001','manager@carepath-staging.example'),
 ('00000000-0000-0000-0000-0000000000a1','eruiz@rosenthalkaye.example'),
 ('00000000-0000-0000-0000-0000000000b1','pshah@brennaninjury.example'),
 ('00000000-0000-0000-0000-0000000000c1','dwhitfield@commonwealthcas.example'),
 ('00000000-0000-0000-0000-0000000000d1','nobody@example.com');
update users set auth_user_id='00000000-0000-0000-0000-000000000001' where id=1;
insert into portal_users(id,email,full_name,role,firm_contact_id) values
 ('00000000-0000-0000-0000-0000000000a1','eruiz@rosenthalkaye.example','Elena Ruiz','firm_admin','ct_rk'),
 ('00000000-0000-0000-0000-0000000000b1','pshah@brennaninjury.example','Priya Shah','firm_user','ct_bil'),
 ('00000000-0000-0000-0000-0000000000c1','dwhitfield@commonwealthcas.example','Dana Whitfield','third_party',null);
SQL
as() { # $1=uuid $2=amr method $3=sql
  $D -tA -c "set role authenticated; select set_config('request.jwt.claims', json_build_object('sub','$1','amr',json_build_array(json_build_object('method','$2')),'session_id','11111111-1111-1111-1111-$(echo $1 | tail -c 13)')::text, false); $3" | tail -1; }
anon() { $D -tA -c "set role anon; $1" 2>&1 | tail -1; }
check() { [ "$2" = "$3" ] && echo "PASS $1 ($2)" || { echo "FAIL $1: got '$2' expected '$3'"; FAILS=1; }; }
FAILS=0
M=00000000-0000-0000-0000-000000000001; RK=00000000-0000-0000-0000-0000000000a1; BI=00000000-0000-0000-0000-0000000000b1; TP=00000000-0000-0000-0000-0000000000c1; NB=00000000-0000-0000-0000-0000000000d1

echo "== public key alone"
check "anon cannot read cases" "$(anon 'select count(*) from cases' | grep -o 'permission denied' | head -1)" "permission denied"
check "anon cannot read users" "$(anon 'select count(*) from users' | grep -o 'permission denied' | head -1)" "permission denied"
check "anon cannot list portal cases" "$(anon 'select count(*) from portal_list_cases()' | grep -o 'permission denied' | head -1)" "permission denied"

echo "== staff"
check "staff sees all 15 cases" "$(as $M password 'select count(*) from cases')" "15"
check "staff sees all 16 referrals" "$(as $M password 'select count(*) from referrals')" "16"
check "staff cannot read passwords" "$(as $M password 'select password from users limit 1' 2>&1 | grep -o 'permission denied' | head -1)" "permission denied"
check "staff can read roster" "$(as $M password 'select count(*) from users')" "4"
check "non-staff login sees no CRM cases" "$(as $NB otp 'select count(*) from cases')" "0"

echo "== firm matching (nothing linked until approved)"
check "firm sees 0 before matches approved" "$(as $RK otp 'select count(*) from portal_list_cases()')" "0"
as $M password "select portal_suggest_firm_matches()" >/dev/null
$D -tA -c "select raw_name, coalesce(contact_id,'NO MATCH - needs a person') from firm_name_matches order by raw_name"
as $M password "update firm_name_matches set status='approved', reviewed_by='Test Manager', reviewed_at=now() where contact_id is not null" >/dev/null
as $M password "update firm_name_matches set contact_id='ct_olg', status='approved', reviewed_by='Test Manager' where raw_name='Okafor Law Group'" >/dev/null
echo "apply: $(as $M password 'select portal_apply_firm_matches()')"
check "every represented case now linked" "$($D -tAc "select count(*) from cases where law_firm is not null and firm_contact_id is null")" "0"
check "typed-in law_firm text untouched" "$($D -tAc "select count(distinct law_firm) from cases where law_firm is not null")" "$($D -tAc "select count(*) from firm_name_matches where case_count>0")"

echo "== partners"
RKN=$($D -tAc "select count(*) from cases where firm_contact_id='ct_rk'")
check "Rosenthal sees only its own cases" "$(as $RK otp 'select count(*) from portal_list_cases()')" "$RKN"
check "Rosenthal reading cases table directly gets nothing" "$(as $RK otp 'select count(*) from cases')" "0"
check "Rosenthal cannot see Brennan appointments" "$(as $RK otp "select count(*) from appointments a join cases c on c.id=a.case_id where c.firm_contact_id='ct_bil'")" "0"
check "Rosenthal sees its appointments" "$(as $RK otp "select count(*)>0 from appointments")" "t"
check "password sign-in on unremembered device sees nothing" "$(as $RK password 'select count(*) from portal_list_cases()')" "0"
NEWID=$(as $BI otp "select portal_submit_referral('{\"first_name\":\"Ana\",\"last_name\":\"Torres\",\"case_type\":\"WC\",\"doi\":\"2026-10-20\",\"location\":\"Allentown\",\"attorney\":\"Priya Shah\"}'::jsonb)")
check "portal referral lands in CRM queue" "$($D -tAc "select status||'|'||submitted_via||'|'||law_firm||'|'||coalesce(alert_assigned_to,'unassigned') from referrals where id='$NEWID'")" "Pending Scheduling|portal|Brennan Injury Law|unassigned"
check "staff sees the portal referral" "$(as $M password "select count(*) from referrals where id='$NEWID'")" "1"
check "Brennan sees its referral" "$(as $BI otp "select count(*) from portal_list_referrals() where referral_id='$NEWID'")" "1"
check "Rosenthal cannot see Brennan's referral" "$(as $RK otp "select count(*) from portal_list_referrals() where referral_id='$NEWID'")" "0"
check "Rosenthal cannot submit as a third party" "$(as $TP otp "select portal_submit_referral('{\"first_name\":\"X\",\"last_name\":\"Y\",\"case_type\":\"WC\"}'::jsonb)" 2>&1 | grep -o 'Only signed-in law firm users' )" "Only signed-in law firm users"
BCASE=$($D -tAc "select id from cases where firm_contact_id='ct_bil' limit 1")
check "Rosenthal cannot message on Brennan case" "$(as $RK otp "insert into portal_messages(case_id,author_partner,kind,body) values ('$BCASE','$RK','message','hi')" 2>&1 | grep -o 'row-level security' | head -1)" "row-level security"
check "Brennan can message on own case" "$(as $BI otp "insert into portal_messages(case_id,author_partner,kind,body) values ('$BCASE','$BI','records_request','Need updated records'); select count(*) from portal_messages where case_id='$BCASE' and author_partner='$BI'")" "1"
check "partner cannot post as staff" "$(as $BI otp "insert into portal_messages(case_id,author_staff,kind,body) values ('$BCASE',4,'update','fake')" 2>&1 | grep -o 'row-level security' | head -1)" "row-level security"

echo "== third party (appointments only, on one case)"
TCASE=$($D -tAc "select id from cases where firm_contact_id='ct_rk' limit 1")
as $M password "select grant_access('$TCASE','$TP',array['appointments'],now()+interval '30 days')" >/dev/null
check "third party sees exactly 1 case" "$(as $TP otp 'select count(*) from portal_list_cases()')" "1"
check "third party sees its appointments" "$(as $TP otp "select count(*)>0 from appointments where case_id='$TCASE'")" "t"
check "third party cannot see documents" "$(as $TP otp "select count(*) from portal_documents where case_id='$TCASE'")" "0"
check "third party cannot see referrals" "$(as $TP otp 'select count(*) from portal_list_referrals()')" "0"
GID=$($D -tAc "select id from access_grants where user_id='$TP' limit 1")
as $M password "select revoke_access('$GID')" >/dev/null
check "revoked third party sees nothing" "$(as $TP otp 'select count(*) from portal_list_cases()')" "0"
check "access log recorded events" "$($D -tAc "select count(*)>=3 from portal_access_log")" "t"

echo "== rollback restores today's behaviour"
$D -f sql/900_rollback.sql
check "anon can read cases again after rollback" "$(anon 'select count(*) from cases')" "15"
check "portal tables still locked to anon after rollback" "$(anon 'select count(*) from portal_documents' | grep -o 'permission denied' | head -1)" "permission denied"
[ $FAILS = 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
