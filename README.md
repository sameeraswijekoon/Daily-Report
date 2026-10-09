# VisitLog — Daily Customer Visit Reporting

A responsive React + TypeScript customer visit reporting application with Supabase authentication, PostgreSQL persistence, role-based access, and formatted Excel exports.

## Features

- Username/password sign-in using Supabase Auth; password hashes are managed by Supabase Auth.
- Admin and User roles, active/inactive accounts, user creation, username changes, role assignment, and password resets.
- Customer visit capture with date selection, reason, remarks, start/end time, and duration validation.
- Dashboard statistics, recent visits, city distribution, and visit-purpose breakdown.
- Searchable/filterable visit register and XLSX workbook with a visit register plus summaries.
- PostgreSQL Row Level Security (RLS) scopes user records and enforces admin-only access to company-wide reports.
- Responsive desktop, tablet, and mobile layout.

## Deployment setup

This repository is a static Vite frontend with Supabase as the hosted backend. GitHub Pages cannot host a Node server or PostgreSQL database itself.

### 1. Create a Supabase project

Create a project at https://supabase.com/dashboard.

### 2. Set up the database

Open **SQL Editor** in Supabase and run all of `database/setup.sql`.

The script creates `profiles` and `visit_reports`, indexes, update timestamps, username lookup, role/status RPCs, and row-level security policies.

### 3. Create the first administrator

In **Authentication → Users**, create a confirmed user with:
- Email: `admin@visitlog.app`
- A strong password
- User metadata: `{"username":"admin"}`

Then run this in SQL Editor:

```sql
update public.profiles
set role = 'Admin', active = true
where lower(username) = 'admin';
```

Use username `admin` and the password you set to sign in. Change the username/password after first login as appropriate. The email is an internal username mapping and does not need to receive mail.

### 4. Deploy the admin Edge Function

Install the Supabase CLI and link the project, then deploy:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy admin-user-management
```

The Edge Function uses the project's `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` server-side secrets. Supabase provides these to deployed functions. Never add the service-role key to Vite variables, GitHub, or browser code.

The function verifies the caller's current authenticated session and active Admin role before creating users, changing usernames, or resetting passwords.

### 5. Configure frontend environment variables

Copy `.env.example` to `.env.local` (never commit `.env.local`) and use the values from Supabase **Project Settings → API**. This is a Vite/React single-page application, so its frontend variables use the `VITE_` prefix (not Next.js `NEXT_PUBLIC_`):

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_SUPABASE_PUBLISHABLE_KEY
```

Only the public anon/publishable key belongs in the frontend. RLS is the security boundary.

### 6. Run locally

```sh
npm install
npm run dev
```

To check and build:

```sh
npm run build
npm run preview
```

### 7. Deploy on GitHub Pages

In GitHub, open **Settings → Pages** and select **GitHub Actions** as the build source. Add these repository Actions variables (Settings → Secrets and variables → Actions → Variables):
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

The included workflow builds and publishes the Vite app on pushes to `main`. If the repository uses a different branch, update the workflow trigger.

## Important security notes

- Do not disable RLS or expose the Supabase service-role key.
- User passwords are never stored in application tables; Supabase Auth handles password hashing.
- Users can read and mutate only their own visit rows. Admins can read/manage all visit rows.
- Username changes update both the Auth email mapping and profile username.
- Backups and point-in-time recovery depend on the Supabase plan and project configuration; enable appropriate database backups for business use.
- Review and test policies with separate Admin and User accounts before using real customer data.
- A visit crossing midnight is not supported by the same-day time-only form; record the correct date/time according to company policy.

## Technology

React, TypeScript, Vite, `@supabase/supabase-js`, Supabase Auth/PostgreSQL/RLS/Edge Functions, Lucide React, ExcelJS.

### Why this project does not use `@supabase/ssr`

The provided `@supabase/ssr` examples (`next/headers`, `page.tsx`, and Next.js middleware) are for Next.js server-side rendering. This repository uses Vite and React, with no Next.js server or middleware. It therefore uses `@supabase/supabase-js` directly in a shared browser client (`src/lib/supabase.ts`). Do not add Next.js-specific server/middleware files unless the application is intentionally migrated to Next.js. The existing `@supabase/supabase-js` dependency is already declared in `package.json`, so it does not need to be installed again.
