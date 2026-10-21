-- Idempotent role setup, run as the RDS master user against the application database.
-- Environment: APP_USER, APP_PASSWORD, MIGRATOR_USER, MIGRATOR_PASSWORD (from the role secrets, read with \getenv so
-- they never appear on a command line). psql variable: app_connection_limit.
-- (psql doesn't substitute variables inside DO blocks, so conditional DDL uses SELECT format(...) \gexec.)

\set ON_ERROR_STOP on
\getenv app_user APP_USER
\getenv app_password APP_PASSWORD
\getenv migrator_user MIGRATOR_USER
\getenv migrator_password MIGRATOR_PASSWORD

-- 1. Roles exist and have the current passwords.
SELECT format('CREATE ROLE %I LOGIN', :'migrator_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'migrator_user') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'app_user')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app_user') \gexec

ALTER ROLE :"migrator_user" WITH LOGIN PASSWORD :'migrator_password';
ALTER ROLE :"app_user" WITH LOGIN CONNECTION LIMIT :app_connection_limit PASSWORD :'app_password';

-- The master (not a superuser on RDS) must be able to SET ROLE to the migrator to hand it ownership, and inherit
-- its privileges to grant on its tables and set its default privileges. On PostgreSQL 16+ the role's creator only
-- gets ADMIN membership (no SET, no INHERIT), so grant both explicitly.
SELECT format('GRANT %I TO CURRENT_USER WITH INHERIT TRUE, SET TRUE', :'migrator_user')
 WHERE NOT (pg_has_role(current_user, :'migrator_user', 'SET') AND pg_has_role(current_user, :'migrator_user', 'USAGE')) \gexec

-- 2. The migrator owns the database. On PostgreSQL 15+ schema public belongs to pg_database_owner, so the database
-- owner can create in it: Prisma migrations run as the migrator.
SELECT format('ALTER DATABASE %I OWNER TO %I', current_database(), :'migrator_user') \gexec

-- Tables created earlier by the master user (none on a fresh database) move to the migrator.
SELECT format('ALTER TABLE public.%I OWNER TO %I', tablename, :'migrator_user')
  FROM pg_tables WHERE schemaname = 'public' AND tableowner = current_user \gexec

-- 3. Only the two roles (and the master) may connect.
SELECT format('REVOKE CONNECT, TEMPORARY ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec

-- 4. The app role: data access only, on existing objects and on everything the migrator creates later.
GRANT USAGE ON SCHEMA public TO :"app_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_user";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_user" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES FOR ROLE :"migrator_user" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";

-- 5. Report.
SELECT r.rolname, r.rolconnlimit,
       has_database_privilege(r.rolname, current_database(), 'CONNECT') AS can_connect,
       has_schema_privilege(r.rolname, 'public', 'CREATE') AS can_create_in_public
  FROM pg_roles r WHERE r.rolname IN (:'migrator_user', :'app_user') ORDER BY 1;
