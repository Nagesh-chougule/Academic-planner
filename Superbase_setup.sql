-- =====================================================================
-- Department Academic Planner — Supabase schema (v2)
-- Paste this entire file into Supabase Dashboard → SQL Editor → New query → Run
--
-- v2 fix: column names now match EXACTLY what the app's JS sends
-- (camelCase: totalTarget, semMin, semMax, programId, facultyName, etc.)
-- instead of snake_case. That mismatch is what caused:
--   "Could not find the 'semMax' column of 'programs' in the schema cache"
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. CLEAN SLATE — drops these six tables (and any data in them) so the
--    schema below can be created fresh. Export via the app's Excel
--    Export button first if you need to keep existing data, then
--    re-import the workbook after creating your account.
-- ---------------------------------------------------------------------
drop view  if exists public.v_timetable_full;
drop table if exists public.timetable   cascade;
drop table if exists public.assignments cascade;
drop table if exists public.courses     cascade;
drop table if exists public.faculty     cascade;
drop table if exists public.programs    cascade;
drop table if exists public.department  cascade;

create extension if not exists pgcrypto; -- gives us gen_random_uuid()

-- =====================================================================
-- 1. TABLES
-- =====================================================================
-- Ownership model: every row belongs to exactly one auth.users row (user_id),
-- forced server-side by a trigger — never trusted from the client.
-- Column names in quotes preserve the camelCase the app's JS already uses;
-- this is a deliberately denormalized shape (programName/code/facultyName
-- are duplicated onto child rows) because that's the flat row shape the
-- app's flatten/inflate functions already produce and expect back.

-- ---- department: one row per user --------------------------------------
create table public.department (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  "name"      text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---- programs ------------------------------------------------------------
create table public.programs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  "name"        text not null default '',
  "type"        text not null default 'UG4' check ("type" in ('UG4','PG2','PG1')),
  "major"       text not null default '',
  "minor"       text not null default '',
  "totalTarget" numeric not null default 160 check ("totalTarget" >= 0),
  "semMin"      numeric not null default 20 check ("semMin" >= 0),
  "semMax"      numeric not null default 22 check ("semMax" >= 0),
  "semesters"   integer not null default 8 check ("semesters" between 1 and 8),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint programs_sem_range check ("semMax" >= "semMin")
);

-- ---- faculty ---------------------------------------------------------------
create table public.faculty (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  "name"           text not null default '',
  "designation"    text not null default '',
  "specialization" text not null default '',
  "maxLoad"        numeric not null default 16 check ("maxLoad" > 0 and "maxLoad" <= 40),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---- courses -----------------------------------------------------------
create table public.courses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  "programId"   uuid not null references public.programs(id) on delete cascade,
  "programName" text not null default '',
  "sem"         integer not null default 1 check ("sem" between 1 and 8),
  "code"        text not null default '',
  "title"       text not null default '',
  "category"    text not null default '',
  "L"           numeric not null default 0 check ("L" >= 0),
  "T"           numeric not null default 0 check ("T" >= 0),
  "P"           numeric not null default 0 check ("P" >= 0),
  "credits"     numeric not null default 0 check ("credits" >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint courses_program_sem_code_unique unique ("programId", "sem", "code")
);

-- ---- assignments (faculty load per course) ------------------------------
create table public.assignments (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "courseId"     uuid not null references public.courses(id) on delete cascade,
  "programName"  text not null default '',
  "sem"          integer not null default 1,
  "code"         text not null default '',
  "facultyId"    uuid not null references public.faculty(id) on delete cascade,
  "facultyName"  text not null default '',
  "hours"        numeric not null default 0 check ("hours" >= 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint assignments_course_faculty_unique unique ("courseId", "facultyId")
);

-- ---- timetable -------------------------------------------------------
create table public.timetable (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "programId"    uuid not null references public.programs(id) on delete cascade,
  "programName"  text not null default '',
  "semester"     integer not null default 1 check ("semester" between 1 and 8),
  "division"     text not null default 'A',
  "day"          text not null default 'Mon' check ("day" in ('Mon','Tue','Wed','Thu','Fri','Sat')),
  "period"       integer not null default 1 check ("period" between 1 and 7),
  "courseId"     uuid references public.courses(id) on delete cascade,
  "code"         text not null default '',
  "facultyId"    uuid references public.faculty(id) on delete set null,
  "facultyName"  text not null default '',
  "room"         text not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint timetable_slot_unique unique ("programId", "semester", "division", "day", "period")
);

-- =====================================================================
-- 2. INDEXES
-- =====================================================================
create index idx_programs_user      on public.programs(user_id);
create index idx_faculty_user       on public.faculty(user_id);
create index idx_courses_user       on public.courses(user_id);
create index idx_assignments_user   on public.assignments(user_id);
create index idx_timetable_user     on public.timetable(user_id);

create index idx_courses_program    on public.courses("programId");
create index idx_assignments_course on public.assignments("courseId");
create index idx_assignments_faculty on public.assignments("facultyId");
create index idx_timetable_program  on public.timetable("programId");
create index idx_timetable_course   on public.timetable("courseId");
create index idx_timetable_faculty  on public.timetable("facultyId");

-- =====================================================================
-- 3. TRIGGERS
-- =====================================================================

-- 3a. Force user_id = auth.uid() on every insert, ignoring anything the
--     client sends — makes the exposed anon key safe even if the client
--     JS is tampered with.
create or replace function public.set_owner_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.user_id := auth.uid();
  return new;
end;
$$;

-- 3b. On update: keep ownership immutable and stamp updated_at.
create or replace function public.touch_and_lock_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.user_id := old.user_id;
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['department','programs','faculty','courses','assignments','timetable'] loop
    execute format('create trigger trg_%1$s_set_owner before insert on public.%1$s
                    for each row execute function public.set_owner_on_insert()', t);
    execute format('create trigger trg_%1$s_touch before update on public.%1$s
                    for each row execute function public.touch_and_lock_owner()', t);
  end loop;
end $$;

-- =====================================================================
-- 4. ROW LEVEL SECURITY
-- =====================================================================
alter table public.department   enable row level security;
alter table public.programs     enable row level security;
alter table public.faculty      enable row level security;
alter table public.courses      enable row level security;
alter table public.assignments  enable row level security;
alter table public.timetable    enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['department','programs','faculty','courses','assignments','timetable'] loop
    execute format('create policy "select own %1$s" on public.%1$s
                    for select using (user_id = auth.uid())', t);
    execute format('create policy "insert own %1$s" on public.%1$s
                    for insert with check (user_id = auth.uid())', t);
    execute format('create policy "update own %1$s" on public.%1$s
                    for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('create policy "delete own %1$s" on public.%1$s
                    for delete using (user_id = auth.uid())', t);
  end loop;
end $$;

-- Note: the BEFORE INSERT trigger already overwrites user_id with auth.uid()
-- before the "insert with check" runs, so the check always passes for
-- genuine inserts — it's defense in depth, documenting the invariant at
-- the RLS layer as well as the trigger layer.

-- =====================================================================
-- 5. CONVENIENCE VIEW (used by Export / Print and Clash Report pages)
-- =====================================================================
create or replace view public.v_timetable_full
with (security_invoker = true) as
select
  tt.id,
  tt.user_id,
  tt."programId"   as "programId",
  tt."programName" as "programName",
  tt."semester"    as "semester",
  tt."division"    as "division",
  tt."day"         as "day",
  tt."period"      as "period",
  tt."courseId"    as "courseId",
  tt."code"        as "code",
  c."title"        as "courseTitle",
  tt."facultyId"   as "facultyId",
  tt."facultyName" as "facultyName",
  tt."room"        as "room"
from public.timetable tt
left join public.courses c on c.id = tt."courseId";

-- security_invoker = true means this view respects the RLS of the querying
-- user (their own rows only) rather than the view owner's permissions.

-- =====================================================================
-- Done. Next: Authentication → Providers → Email (see setup guide),
-- then open the app and create your first account.
-- =====================================================================
