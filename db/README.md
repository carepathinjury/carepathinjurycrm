# Database changes for the partner portal

Branch: `portal-integration`. Nothing here runs against the live project until launch.

| File | Where | When |
|---|---|---|
| `migrations/001_portal_foundation.sql` | live | Any time before launch. Add-only; current CRM unaffected. |
| `migrations/900_cutover_access_rules.sql` | live | Launch day only, together with the new CRM. |
| `migrations/900_rollback.sql` | live | Emergency only: restores today's behavior. |
| `staging/STAGING_SETUP_run_once.sql` | staging only | Once, on the staging project. |
| `staging/staging_link_test_logins.sql` | staging only | After creating test logins. |
| `tests/run_tests.sh` | local | Checks add-only safety and every access rule. |

Rule: every change to live CRM tables made on `main` during the build must also be reflected here.
