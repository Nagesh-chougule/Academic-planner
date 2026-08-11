-- =====================================================================
-- Department Academic Planner — Supabase schema (v7)
-- Paste this entire file into Supabase Dashboard → SQL Editor → New query → Run
--
-- v3 added: Academic Years, Curriculum Versions (multiple versions per year,
-- exactly one Active per year), and Syllabus attachments (Supabase Storage).
--
-- v4 added: granular Theory (L) / Tutorial (T) / Practical (P) columns —
-- "assignedL", "assignedT", "assignedP" — on public.assignments, so a
-- faculty member's slice of a course's load is stored component-by-component
-- instead of as one lump "hours" figure. "hours" is kept as the row's total
-- (assignedL + assignedT + assignedP) for backward compatibility with any
-- existing reports/exports that only read "hours".
--
-- v5 adds: batch/division-wise Load Distribution.
--   * public.programs gains "divisionsCount" (integer, default 1) — how many
--     parallel batches/divisions (Division A, Division B, ...) the programme
--     is split into for faculty allocation purposes.
--   * public.assignments gains "division" (text, default 'Division A') so a
--     faculty member's L/T/P slice of a course is scoped to one division —
--     the same course+faculty pair can now have one row per division (e.g.
--     Prof. X teaches Theory to Division A while Prof. Y teaches Practical
--     to Division B). The old one-row-per-course-per-faculty uniqueness is
--     replaced with one-row-per-course-per-faculty-per-division.
--
-- v6 adds: Curriculum Builder "Minors" and "Honors" tabs.
--   * public.courses gains "kind" text (default 'Regular', check in
--     ('Regular','Minor','Honors')) so Minor-Programme and Honors-Programme
--     courses are tagged and stored separately from the regular Semester
--     I–VIII curriculum, without touching Sem I–VIII credit calculations.
--   * public.courses "sem" check is relaxed to "between 0 and 8" — Minor/
--     Honors rows carry sem = 0 (not applicable; they aren't tied to a
--     specific semester), while every regular row keeps using 1–8 exactly
--     as before.
--   * The "courses_program_sem_code_unique" constraint becomes
--     ("programId","sem","kind","code") so a Minor course and an Honors
--     course under the same programme (both at sem = 0) may reuse the same
--     course code without colliding with each other.
--
-- This is a CLEAN-SLATE script like v2/v3/v4: it drops the tables (and any
-- data in them) and rebuilds everything, including the "syllabi" storage
-- bucket. Export via the app's Excel Export button first if you need to
-- keep existing data, then re-import the workbook after running this
-- script and creating your first Academic Year + Version.
--
-- Upgrading an existing v4 database WITHOUT wiping data? Skip this whole
-- script and instead run only the migration block at the very bottom
-- of this file (search for "IN-PLACE MIGRATION").
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. CLEAN SLATE
-- ---------------------------------------------------------------------
drop view  if exists public.v_timetable_full;
drop table if exists public.syllabus_files      cascade;
drop table if exists public.tt_schedules        cascade;
drop table if exists public.tt_rooms            cascade;
drop table if exists public.tt_batches          cascade;
drop table if exists public.timetable           cascade;  -- legacy; now replaced by tt_schedules
drop table if exists public.assignments         cascade;
drop table if exists public.courses             cascade;
drop table if exists public.faculty             cascade;
drop table if exists public.programs            cascade;
drop table if exists public.curriculum_versions cascade;
drop table if exists public.academic_years      cascade;
drop table if exists public.department          cascade;

create extension if not exists pgcrypto; -- gives us gen_random_uuid()

-- =====================================================================
-- 1. TABLES
-- =====================================================================
-- Ownership model unchanged: every row belongs to exactly one auth.users
-- row (user_id), forced server-side by a trigger — never trusted from
-- the client. Column names in quotes preserve the camelCase the app's
-- JS already uses.

-- ---- department: one row per user --------------------------------------
create table public.department (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  "name"      text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---- academic_years --------------------------------------------------
-- e.g. label = '2025-2026'. One department can have several, one per year.
create table public.academic_years (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "label"     text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint academic_years_label_unique unique (user_id, "label")
);

-- ---- curriculum_versions ----------------------------------------------
-- Every programme/course structure hangs off exactly one version row.
-- A version belongs to exactly one academic year. Exactly one version
-- per academic year may have status = 'Active' (enforced by the partial
-- unique index below) — all others are 'Inactive' (read-only by
-- convention in the UI, but still editable if the user switches to them).
create table public.curriculum_versions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users(id) on delete cascade,
  "academicYearId"  uuid not null references public.academic_years(id) on delete cascade,
  "versionLabel"    text not null default '1.0',
  "status"          text not null default 'Inactive' check ("status" in ('Active','Inactive')),
  "notes"           text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint curriculum_versions_label_unique unique ("academicYearId", "versionLabel")
);

-- Only one Active version per academic year, department-wide (per user).
create unique index idx_one_active_version_per_year
  on public.curriculum_versions ("academicYearId")
  where "status" = 'Active';

-- ---- programs ------------------------------------------------------------
-- Now version-scoped: a programme row belongs to exactly one curriculum
-- version. "Create New Version" deep-copies every programme+course row
-- for the previous version into new rows tagged with the new versionId,
-- leaving the originals untouched for audit/history.
create table public.programs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  "versionId"   uuid not null references public.curriculum_versions(id) on delete cascade,
  "name"        text not null default '',
  "type"        text not null default 'UG4' check ("type" in ('UG4','PG2','PG1')),
  "major"       text not null default '',
  "minor"       text not null default '',
  "totalTarget" numeric not null default 160 check ("totalTarget" >= 0),
  "semMin"      numeric not null default 20 check ("semMin" >= 0),
  "semMax"      numeric not null default 22 check ("semMax" >= 0),
  "semesters"   integer not null default 8 check ("semesters" between 1 and 8),
  "divisionsCount" integer not null default 1 check ("divisionsCount" >= 1),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint programs_sem_range check ("semMax" >= "semMin")
);

-- ---- faculty ---------------------------------------------------------------
-- Faculty are NOT version-scoped — a department's faculty roster is shared
-- across academic years/versions; only the curriculum (programs/courses)
-- and syllabus attachments are versioned.
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
  "sem"         integer not null default 1 check ("sem" between 0 and 8), -- 0 = n/a (Minor/Honors rows)
  "code"        text not null default '',
  "title"       text not null default '',
  "category"    text not null default '',
  "kind"        text not null default 'Regular' check ("kind" in ('Regular','Minor','Honors')),
  "L"           numeric not null default 0 check ("L" >= 0),
  "T"           numeric not null default 0 check ("T" >= 0),
  "P"           numeric not null default 0 check ("P" >= 0),
  "credits"     numeric not null default 0 check ("credits" >= 0),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  -- "kind" is part of the uniqueness key so a Minor course and an Honors
  -- course (both stored at sem = 0) can share the same code.
  constraint courses_program_sem_code_unique unique ("programId", "sem", "kind", "code")
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
  "division"     text not null default 'Division A',
  "assignedL"    numeric not null default 0 check ("assignedL" >= 0),
  "assignedT"    numeric not null default 0 check ("assignedT" >= 0),
  "assignedP"    numeric not null default 0 check ("assignedP" >= 0),
  "hours"        numeric not null default 0 check ("hours" >= 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- One row per faculty PER DIVISION on a course — lets the same faculty member
  -- teach different divisions of the same course (e.g. Theory to Div A, Practical to Div B).
  constraint assignments_course_faculty_division_unique unique ("courseId", "facultyId", "division")
);

-- ---- tt_rooms: Classroom/Lab register (per user, for Timetable Board) -------
-- Separate from program data; managed in the Timetable → Classrooms tab.
create table public.tt_rooms (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "name"      text not null default '',
  "capacity"  integer not null default 60 check ("capacity" > 0),
  "type"      text not null default 'Lecture' check ("type" in ('Lecture','Lab')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint tt_rooms_name_user_unique unique (user_id, "name")
);

-- ---- tt_batches: Student batch register (per user, for Timetable Board) ----
-- Each row = one programme + semester + division combination.
-- programme_id is a soft FK (text) so batches survive programme renames.
create table public.tt_batches (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  "progId"     uuid references public.programs(id) on delete cascade,
  "progName"   text not null default '',
  "sem"        integer not null default 1 check ("sem" between 1 and 8),
  "division"   text not null default 'Division A',
  "count"      integer not null default 60 check ("count" >= 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint tt_batches_unique unique (user_id, "progId", "sem", "division")
);

-- ---- tt_schedules: Generated timetable assignments -----------------------
-- Stores each placed session from the auto-generation engine.
-- batchKey is the composite "progId||sem||division" used by the JS engine.
-- This table is always replaced wholesale on each re-generation; it is
-- not intended for manual slot-by-slot editing (use the timetable view
-- for read-only access; re-generate to change the schedule).
create table public.tt_schedules (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "batchKey"    text not null default '',
  "day"         integer not null default 0,  -- 0=Mon … 5=Sat
  "startPeriod" integer not null default 1,
  "length"      integer not null default 1 check ("length" in (1,2)),
  "subjectCode" text not null default '',
  "subjectName" text not null default '',
  "subjectType" text not null default 'Theory' check ("subjectType" in ('Theory','Lab')),
  "facultyName" text not null default '',
  "roomName"    text not null default '',
  created_at     timestamptz not null default now()
);

-- Legacy timetable table is preserved for backward compatibility but no
-- longer written to by the application.  New installs can omit it.
-- (Dropped and re-created as an empty shell with no rows.)
create table public.timetable (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "programId"    uuid references public.programs(id) on delete cascade,
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

-- ---- syllabus_files -----------------------------------------------------
-- Metadata rows for files uploaded to the 'syllabi' Storage bucket.
-- Linked to BOTH the course and the curriculum version so the same course
-- code appearing in two different versions of the curriculum can carry
-- different syllabus documents (Version Isolation requirement).
create table public.syllabus_files (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "courseId"     uuid not null references public.courses(id) on delete cascade,
  "versionId"    uuid not null references public.curriculum_versions(id) on delete cascade,
  "fileName"     text not null default '',
  "storagePath"  text not null default '', -- path inside the 'syllabi' bucket: {user_id}/{courseId}/{uuid}-{fileName}
  "fileSize"     numeric not null default 0,
  created_at     timestamptz not null default now(),
  -- Exactly one syllabus attachment per course per curriculum version. The app
  -- always deletes any existing row before inserting a replacement, but this
  -- constraint is the backend backstop in case two uploads ever race.
  constraint syllabus_files_course_version_unique unique ("courseId", "versionId")
);

-- =====================================================================
-- 2. INDEXES
-- =====================================================================
create index idx_academic_years_user       on public.academic_years(user_id);
create index idx_curriculum_versions_user  on public.curriculum_versions(user_id);
create index idx_curriculum_versions_year  on public.curriculum_versions("academicYearId");
create index idx_programs_user       on public.programs(user_id);
create index idx_programs_version    on public.programs("versionId");
create index idx_faculty_user        on public.faculty(user_id);
create index idx_courses_user        on public.courses(user_id);
create index idx_assignments_user    on public.assignments(user_id);
create index idx_timetable_user      on public.timetable(user_id);
create index idx_tt_rooms_user       on public.tt_rooms(user_id);
create index idx_tt_batches_user     on public.tt_batches(user_id);
create index idx_tt_schedules_user   on public.tt_schedules(user_id);
create index idx_tt_batches_prog     on public.tt_batches("progId");
create index idx_tt_schedules_batch  on public.tt_schedules("batchKey");

create index idx_courses_program     on public.courses("programId");
create index idx_assignments_course  on public.assignments("courseId");
create index idx_assignments_faculty on public.assignments("facultyId");
create index idx_timetable_program   on public.timetable("programId");
create index idx_timetable_course    on public.timetable("courseId");
create index idx_timetable_faculty   on public.timetable("facultyId");

create index idx_syllabus_user       on public.syllabus_files(user_id);
create index idx_syllabus_course     on public.syllabus_files("courseId");
create index idx_syllabus_version    on public.syllabus_files("versionId");

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
  foreach t in array array['department','academic_years','curriculum_versions','programs','faculty','courses','assignments','timetable','tt_rooms','tt_batches'] loop
    execute format('create trigger trg_%1$s_set_owner before insert on public.%1$s
                    for each row execute function public.set_owner_on_insert()', t);
    execute format('create trigger trg_%1$s_touch before update on public.%1$s
                    for each row execute function public.touch_and_lock_owner()', t);
  end loop;
  -- syllabus_files has no updated_at column (append/delete only), so it only
  -- needs the owner-stamping trigger, not the touch trigger.
  execute 'create trigger trg_tt_schedules_set_owner before insert on public.tt_schedules
           for each row execute function public.set_owner_on_insert()';
  execute 'create trigger trg_syllabus_files_set_owner before insert on public.syllabus_files
           for each row execute function public.set_owner_on_insert()';
end $$;

-- 3c. Enforce "exactly one Active version per academic year" from the app
--     side too: whenever a version is set to 'Active', flip every other
--     version in the same academic year to 'Inactive'. This makes the
--     "Set Active" action a single UPDATE from the client instead of a
--     multi-statement transaction, while the partial unique index above
--     remains as a hard backstop.
create or replace function public.deactivate_sibling_versions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."status" = 'Active' then
    update public.curriculum_versions
      set "status" = 'Inactive'
      where "academicYearId" = new."academicYearId"
        and id <> new.id
        and "status" = 'Active';
  end if;
  return new;
end;
$$;

create trigger trg_curriculum_versions_exclusive_active
  after insert or update of "status" on public.curriculum_versions
  for each row execute function public.deactivate_sibling_versions();

-- =====================================================================
-- 4. ROW LEVEL SECURITY
-- =====================================================================
alter table public.department            enable row level security;
alter table public.academic_years        enable row level security;
alter table public.curriculum_versions   enable row level security;
alter table public.programs              enable row level security;
alter table public.faculty               enable row level security;
alter table public.courses               enable row level security;
alter table public.assignments           enable row level security;
alter table public.timetable             enable row level security;
alter table public.tt_rooms              enable row level security;
alter table public.tt_batches            enable row level security;
alter table public.tt_schedules          enable row level security;
alter table public.syllabus_files        enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array['department','academic_years','curriculum_versions','programs','faculty','courses','assignments','timetable','tt_rooms','tt_batches','tt_schedules','syllabus_files'] loop
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

-- =====================================================================
-- 5. CONVENIENCE VIEW (used by Export / Print and Clash Report pages)
-- =====================================================================
-- v_timetable_full: legacy view kept for backward compatibility.
-- New timetable data lives in tt_schedules, tt_rooms, tt_batches.
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

-- v_tt_schedules_full: primary schedule view for the Timetable Board.
create or replace view public.v_tt_schedules_full
with (security_invoker = true) as
select
  s.id,
  s.user_id,
  s."batchKey",
  s."day",
  s."startPeriod",
  s."length",
  s."subjectCode",
  s."subjectName",
  s."subjectType",
  s."facultyName",
  s."roomName",
  s.created_at
from public.tt_schedules s;

-- =====================================================================
-- 6. STORAGE — "syllabi" bucket + policies
-- =====================================================================
-- Private bucket (public = false): files are only reachable via a signed
-- URL created server-side by the app for the owning user, never a public
-- URL. Convention: object path = "{auth.uid()}/{courseId}/{uuid}-{fileName}"
-- so the folder-name policies below can check ownership from the path
-- alone, the same "defense in depth" pattern used by the table RLS above.
insert into storage.buckets (id, name, public)
values ('syllabi', 'syllabi', false)
on conflict (id) do nothing;

drop policy if exists "syllabi select own" on storage.objects;
drop policy if exists "syllabi insert own" on storage.objects;
drop policy if exists "syllabi update own" on storage.objects;
drop policy if exists "syllabi delete own" on storage.objects;

create policy "syllabi select own" on storage.objects
  for select using (
    bucket_id = 'syllabi'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "syllabi insert own" on storage.objects
  for insert with check (
    bucket_id = 'syllabi'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "syllabi update own" on storage.objects
  for update using (
    bucket_id = 'syllabi'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "syllabi delete own" on storage.objects
  for delete using (
    bucket_id = 'syllabi'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- =====================================================================
-- Done. Next: Authentication → Providers → Email (see setup guide),
-- then open the app, create your first account, and add your first
-- Academic Year + Curriculum Version from the toolbar before adding
-- programmes.
-- =====================================================================

-- =====================================================================
-- IN-PLACE MIGRATION (v3 → v4, no data loss)
-- If you already have a v3 database and want to KEEP existing data,
-- do NOT run the script above. Run only this block instead:
-- =====================================================================
-- alter table public.assignments add column if not exists "assignedL" numeric not null default 0 check ("assignedL" >= 0);
-- alter table public.assignments add column if not exists "assignedT" numeric not null default 0 check ("assignedT" >= 0);
-- alter table public.assignments add column if not exists "assignedP" numeric not null default 0 check ("assignedP" >= 0);
-- -- Back-fill existing rows: treat every pre-existing assignment's lump "hours"
-- -- value as pure Theory (L) so nothing silently disappears from Load Summary.
-- -- Adjust manually afterwards in the Load Distribution page as needed.
-- update public.assignments set "assignedL" = "hours" where "assignedL" = 0 and "assignedT" = 0 and "assignedP" = 0 and "hours" > 0;

-- =====================================================================
-- IN-PLACE MIGRATION (v4 → v5, no data loss)
-- If you already have a v4 database (has assignedL/T/P) and want to KEEP
-- existing data, do NOT run the clean-slate script above. Run only this
-- block instead. Every existing programme defaults to 1 division and every
-- existing assignment defaults to "Division A", so nothing changes visually
-- until you raise a programme's "Number of Batches/Divisions" above 1.
-- =====================================================================
-- alter table public.programs add column if not exists "divisionsCount" integer not null default 1 check ("divisionsCount" >= 1);
-- alter table public.assignments add column if not exists "division" text not null default 'Division A';
-- -- Swap the old (courseId, facultyId) uniqueness for (courseId, facultyId, division)
-- -- so the same faculty member can be assigned to more than one division of a course.
-- alter table public.assignments drop constraint if exists assignments_course_faculty_unique;
-- alter table public.assignments add constraint assignments_course_faculty_division_unique unique ("courseId", "facultyId", "division");

-- =====================================================================
-- IN-PLACE MIGRATION (v5 → v6, no data loss)
-- If you already have a v5 database and want to KEEP existing data, do NOT
-- run the clean-slate script above. Run only this block instead. Every
-- existing course row defaults to "kind" = 'Regular', so nothing changes
-- visually until you start adding courses on the new Minors/Honors tabs.
-- =====================================================================
-- alter table public.courses add column if not exists "kind" text not null default 'Regular' check ("kind" in ('Regular','Minor','Honors'));
-- alter table public.courses drop constraint if exists courses_sem_check;
-- alter table public.courses add constraint courses_sem_check check ("sem" between 0 and 8);
-- alter table public.courses drop constraint if exists courses_program_sem_code_unique;
-- alter table public.courses add constraint courses_program_sem_code_unique unique ("programId", "sem", "kind", "code");
