-- =====================================================================
-- Department Academic Planner — Supabase schema (v8 / V11)
-- Paste this entire file into Supabase Dashboard → SQL Editor → New query → Run
--
-- v8 adds: Academic Calendar module.
--   * public.cal_configs     — one calendar configuration per academic year / semester per user
--   * public.cal_events      — holidays, internal tests, college events, exams
--   * public.cal_day_cells   — computed day-cell entries (generated calendar grid rows)
--   * public.cal_approvals   — approval/lock records per calendar config
--
-- This is a CLEAN-SLATE script like previous versions.
-- Run the IN-PLACE MIGRATION block at the bottom instead if you want to
-- keep existing data from v7.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. CLEAN SLATE
-- ---------------------------------------------------------------------
drop view  if exists public.v_timetable_full;
drop view  if exists public.v_tt_schedules_full;
drop table if exists public.cal_approvals      cascade;
drop table if exists public.cal_day_cells      cascade;
drop table if exists public.cal_events         cascade;
drop table if exists public.cal_configs        cascade;
drop table if exists public.syllabus_files     cascade;
drop table if exists public.tt_schedules       cascade;
drop table if exists public.tt_rooms           cascade;
drop table if exists public.tt_batches         cascade;
drop table if exists public.timetable          cascade;
drop table if exists public.assignments        cascade;
drop table if exists public.courses            cascade;
drop table if exists public.faculty            cascade;
drop table if exists public.programs           cascade;
drop table if exists public.curriculum_versions cascade;
drop table if exists public.academic_years     cascade;
drop table if exists public.department         cascade;

create extension if not exists pgcrypto;

-- =====================================================================
-- 1. TABLES  (existing v7 tables first, then new cal_* tables)
-- =====================================================================

-- ---- department: one row per user ----------------------------------------
create table public.department (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  "name"      text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---- academic_years -------------------------------------------------------
create table public.academic_years (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "label"     text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint academic_years_label_unique unique (user_id, "label")
);

-- ---- curriculum_versions --------------------------------------------------
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

create unique index idx_one_active_version_per_year
  on public.curriculum_versions ("academicYearId")
  where "status" = 'Active';

-- ---- programs ---------------------------------------------------------------
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

-- ---- faculty ----------------------------------------------------------------
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

-- ---- courses ----------------------------------------------------------------
create table public.courses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  "programId"   uuid not null references public.programs(id) on delete cascade,
  "programName" text not null default '',
  "sem"         integer not null default 1 check ("sem" between 0 and 8),
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
  constraint courses_program_sem_code_unique unique ("programId", "sem", "kind", "code")
);

-- ---- assignments (faculty load per course) ----------------------------------
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
  constraint assignments_course_faculty_division_unique unique ("courseId", "facultyId", "division")
);

-- ---- tt_rooms ---------------------------------------------------------------
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

-- ---- tt_batches -------------------------------------------------------------
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

-- ---- tt_schedules -----------------------------------------------------------
create table public.tt_schedules (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "batchKey"    text not null default '',
  "day"         integer not null default 0,
  "startPeriod" integer not null default 1,
  "length"      integer not null default 1 check ("length" in (1,2)),
  "subjectCode" text not null default '',
  "subjectName" text not null default '',
  "subjectType" text not null default 'Theory' check ("subjectType" in ('Theory','Lab')),
  "facultyName" text not null default '',
  "roomName"    text not null default '',
  created_at     timestamptz not null default now()
);

-- ---- legacy timetable (kept for backward compatibility) --------------------
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

-- ---- syllabus_files ---------------------------------------------------------
create table public.syllabus_files (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  "courseId"     uuid not null references public.courses(id) on delete cascade,
  "versionId"    uuid not null references public.curriculum_versions(id) on delete cascade,
  "fileName"     text not null default '',
  "storagePath"  text not null default '',
  "fileSize"     numeric not null default 0,
  created_at     timestamptz not null default now(),
  constraint syllabus_files_course_version_unique unique ("courseId", "versionId")
);

-- =====================================================================
-- 1b. NEW TABLES — Academic Calendar (v8)
-- =====================================================================

-- ---- cal_configs: one configuration row per user per academic-year+semester -
-- Stores the semester date bounds, target days, and lecture configuration.
-- "academicYearId" is a soft link (text label) so the calendar module can
-- work independently of the curriculum version selector.
create table public.cal_configs (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  "academicYearId"    uuid references public.academic_years(id) on delete cascade,
  "academicYearLabel" text not null default '',         -- human-readable e.g. "2025-2026"
  "semesterLabel"     text not null default '',         -- e.g. "Semester I (Odd)"
  "semesterType"      text not null default 'odd'
                         check ("semesterType" in ('odd','even')),
  "startDate"         date not null,
  "endDate"           date not null,
  "examStartDate"     date,
  "workingDaysTarget" integer not null default 90
                         check ("workingDaysTarget" > 0),
  "lecturesPerDay"    integer not null default 6
                         check ("lecturesPerDay" > 0 and "lecturesPerDay" <= 12),
  "weekendRule"       text not null default 'sunday_only'
                         check ("weekendRule" in ('sunday_only','sat_sun')),
  "institutionName"   text not null default '',
  "university"        text not null default '',
  "regulation"        text not null default '',
  "isApproved"        boolean not null default false,
  "aiOutput"          text not null default '',         -- last AI-generated analysis text
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- One config per user per academic year per semester type
  constraint cal_configs_unique unique (user_id, "academicYearId", "semesterType")
);

-- ---- cal_events: holidays, internal tests, college events, exams -----------
-- Each row is one dated event attached to a calendar configuration.
-- "configId" cascades on delete so removing a config removes its events.
create table public.cal_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "configId"  uuid not null references public.cal_configs(id) on delete cascade,
  "date"      date not null,
  "name"      text not null default '',
  "type"      text not null default 'holiday'
                 check ("type" in ('holiday','event','test','exam')),
  "remarks"   text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- Prevent duplicate event names on the same date within a config
  constraint cal_events_config_date_name_unique unique ("configId", "date", "name")
);

-- ---- cal_day_cells: pre-computed day classification for each calendar date --
-- Generated (or re-generated) by the app whenever the config or event list
-- changes. Storing these allows fast reporting without re-computing in JS.
-- "classification" mirrors the HOLIDAYS type vocabulary so the front-end
-- CSS classes map 1-to-1.
create table public.cal_day_cells (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  "configId"       uuid not null references public.cal_configs(id) on delete cascade,
  "date"           date not null,
  "classification" text not null default 'working'
                      check ("classification" in ('working','holiday','test','event','exam','sunday','outside')),
  "eventId"        uuid references public.cal_events(id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint cal_day_cells_config_date_unique unique ("configId", "date")
);

-- ---- cal_approvals: audit trail for calendar approvals --------------------
create table public.cal_approvals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "configId"  uuid not null references public.cal_configs(id) on delete cascade,
  "approvedAt" timestamptz not null default now(),
  "approvedBy" text not null default '',    -- free-text signatory name
  "remarks"   text not null default '',
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- 2. INDEXES
-- =====================================================================
-- Existing v7 indexes ---------------------------------------------------
create index idx_academic_years_user       on public.academic_years(user_id);
create index idx_curriculum_versions_user  on public.curriculum_versions(user_id);
create index idx_curriculum_versions_year  on public.curriculum_versions("academicYearId");
create index idx_programs_user             on public.programs(user_id);
create index idx_programs_version          on public.programs("versionId");
create index idx_faculty_user              on public.faculty(user_id);
create index idx_courses_user              on public.courses(user_id);
create index idx_assignments_user          on public.assignments(user_id);
create index idx_timetable_user            on public.timetable(user_id);
create index idx_tt_rooms_user             on public.tt_rooms(user_id);
create index idx_tt_batches_user           on public.tt_batches(user_id);
create index idx_tt_schedules_user         on public.tt_schedules(user_id);
create index idx_tt_batches_prog           on public.tt_batches("progId");
create index idx_tt_schedules_batch        on public.tt_schedules("batchKey");
create index idx_courses_program           on public.courses("programId");
create index idx_assignments_course        on public.assignments("courseId");
create index idx_assignments_faculty       on public.assignments("facultyId");
create index idx_timetable_program         on public.timetable("programId");
create index idx_timetable_course          on public.timetable("courseId");
create index idx_timetable_faculty         on public.timetable("facultyId");
create index idx_syllabus_user             on public.syllabus_files(user_id);
create index idx_syllabus_course           on public.syllabus_files("courseId");
create index idx_syllabus_version          on public.syllabus_files("versionId");

-- New v8 (cal_*) indexes ------------------------------------------------
create index idx_cal_configs_user          on public.cal_configs(user_id);
create index idx_cal_configs_year          on public.cal_configs("academicYearId");
create index idx_cal_events_user           on public.cal_events(user_id);
create index idx_cal_events_config         on public.cal_events("configId");
create index idx_cal_events_date           on public.cal_events("date");
create index idx_cal_day_cells_user        on public.cal_day_cells(user_id);
create index idx_cal_day_cells_config      on public.cal_day_cells("configId");
create index idx_cal_day_cells_date        on public.cal_day_cells("date");
create index idx_cal_approvals_user        on public.cal_approvals(user_id);
create index idx_cal_approvals_config      on public.cal_approvals("configId");

-- =====================================================================
-- 3. TRIGGERS
-- =====================================================================

-- 3a. Force user_id = auth.uid() on every insert
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

-- 3b. Keep ownership immutable and stamp updated_at on update
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

-- Apply set_owner + touch triggers to all tables that have updated_at
do $$
declare
  t text;
begin
  foreach t in array array[
    'department','academic_years','curriculum_versions','programs','faculty',
    'courses','assignments','timetable','tt_rooms','tt_batches',
    'cal_configs','cal_events'
  ] loop
    execute format('create trigger trg_%1$s_set_owner before insert on public.%1$s
                    for each row execute function public.set_owner_on_insert()', t);
    execute format('create trigger trg_%1$s_touch before update on public.%1$s
                    for each row execute function public.touch_and_lock_owner()', t);
  end loop;

  -- Tables with no updated_at: only set_owner trigger
  foreach t in array array['tt_schedules','syllabus_files','cal_day_cells','cal_approvals'] loop
    execute format('create trigger trg_%1$s_set_owner before insert on public.%1$s
                    for each row execute function public.set_owner_on_insert()', t);
  end loop;
end $$;

-- 3c. Enforce "exactly one Active version per academic year"
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

-- 3d. Auto-sync cal_configs.isApproved when an approval row is inserted
--     (one-way: inserting a cal_approvals row locks the config)
create or replace function public.sync_cal_config_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.cal_configs
    set "isApproved" = true, updated_at = now()
    where id = new."configId";
  return new;
end;
$$;

create trigger trg_cal_approvals_sync
  after insert on public.cal_approvals
  for each row execute function public.sync_cal_config_approval();

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
-- New cal_* tables
alter table public.cal_configs           enable row level security;
alter table public.cal_events            enable row level security;
alter table public.cal_day_cells         enable row level security;
alter table public.cal_approvals         enable row level security;

do $$
declare
  t text;
begin
  foreach t in array array[
    'department','academic_years','curriculum_versions','programs','faculty',
    'courses','assignments','timetable','tt_rooms','tt_batches','tt_schedules',
    'syllabus_files','cal_configs','cal_events','cal_day_cells','cal_approvals'
  ] loop
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
-- 5. SUPABASE RPC FUNCTIONS — Academic Calendar
-- =====================================================================

-- rpc: upsert_cal_config
-- Creates or replaces the calendar configuration for the given
-- (user, academicYearId, semesterType) triple.  The client calls this
-- instead of raw INSERT/UPDATE so the server always stamps user_id.
create or replace function public.upsert_cal_config(
  p_academic_year_id    uuid,
  p_academic_year_label text,
  p_semester_label      text,
  p_semester_type       text,
  p_start_date          date,
  p_end_date            date,
  p_exam_start_date     date,
  p_working_days_target integer,
  p_lectures_per_day    integer,
  p_weekend_rule        text,
  p_institution_name    text,
  p_university          text,
  p_regulation          text
)
returns public.cal_configs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config public.cal_configs;
begin
  insert into public.cal_configs (
    user_id, "academicYearId", "academicYearLabel", "semesterLabel",
    "semesterType", "startDate", "endDate", "examStartDate",
    "workingDaysTarget", "lecturesPerDay", "weekendRule",
    "institutionName", "university", "regulation"
  ) values (
    auth.uid(), p_academic_year_id, p_academic_year_label, p_semester_label,
    p_semester_type, p_start_date, p_end_date, p_exam_start_date,
    p_working_days_target, p_lectures_per_day, p_weekend_rule,
    p_institution_name, p_university, p_regulation
  )
  on conflict (user_id, "academicYearId", "semesterType") do update set
    "academicYearLabel"  = excluded."academicYearLabel",
    "semesterLabel"      = excluded."semesterLabel",
    "startDate"          = excluded."startDate",
    "endDate"            = excluded."endDate",
    "examStartDate"      = excluded."examStartDate",
    "workingDaysTarget"  = excluded."workingDaysTarget",
    "lecturesPerDay"     = excluded."lecturesPerDay",
    "weekendRule"        = excluded."weekendRule",
    "institutionName"    = excluded."institutionName",
    "university"         = excluded."university",
    "regulation"         = excluded."regulation",
    "isApproved"         = false,   -- any config change un-approves it
    updated_at           = now()
  returning * into v_config;

  return v_config;
end;
$$;

-- rpc: regenerate_cal_day_cells
-- Deletes all day-cell rows for a given config and recomputes them from
-- the config date range and the current event list.  Call this after
-- any event is added, edited, or removed, or after the config dates change.
create or replace function public.regenerate_cal_day_cells(p_config_id uuid)
returns integer            -- number of rows inserted
language plpgsql
security definer
set search_path = public
as $$
declare
  v_config    public.cal_configs;
  v_cur_date  date;
  v_class     text;
  v_event     public.cal_events;
  v_count     integer := 0;
begin
  -- Ownership check: config must belong to caller
  select * into v_config
    from public.cal_configs
    where id = p_config_id and user_id = auth.uid();
  if not found then
    raise exception 'calendar config not found or access denied';
  end if;

  -- Wipe previous cells for this config
  delete from public.cal_day_cells
    where "configId" = p_config_id and user_id = auth.uid();

  v_cur_date := v_config."startDate";

  while v_cur_date <= v_config."endDate" loop
    -- Determine classification
    if extract(dow from v_cur_date) = 0 then
      -- Sunday
      v_class := 'sunday';
      v_event := null;
    elsif v_config."weekendRule" = 'sat_sun' and extract(dow from v_cur_date) = 6 then
      -- Saturday when full weekend rule is active
      v_class := 'sunday';
      v_event := null;
    else
      -- Check if there is a cal_event on this date
      select * into v_event
        from public.cal_events
        where "configId" = p_config_id
          and "date" = v_cur_date
          and user_id = auth.uid()
        limit 1;

      if found then
        v_class := v_event."type";   -- holiday / test / event / exam
      else
        v_class := 'working';
      end if;
    end if;

    insert into public.cal_day_cells
      (user_id, "configId", "date", "classification", "eventId")
    values
      (auth.uid(), p_config_id, v_cur_date, v_class,
       case when v_event.id is not null then v_event.id else null end);

    v_count  := v_count + 1;
    v_cur_date := v_cur_date + interval '1 day';
  end loop;

  return v_count;
end;
$$;

-- rpc: cal_working_day_summary
-- Returns a JSON summary of working-day counts grouped by month for
-- a given config.  Used by the Editable Report to populate the
-- "Month-wise Working Day Summary" table.
create or replace function public.cal_working_day_summary(p_config_id uuid)
returns table (
  yr          integer,
  mo          integer,
  total_days  integer,
  working     integer,
  holidays    integer,
  events      integer
)
language sql
security definer
set search_path = public
as $$
  select
    extract(year  from "date")::integer as yr,
    extract(month from "date")::integer as mo,
    count(*)::integer                              as total_days,
    count(*) filter (where "classification" = 'working')::integer  as working,
    count(*) filter (where "classification" = 'holiday')::integer  as holidays,
    count(*) filter (where "classification" in ('event','test','exam'))::integer as events
  from public.cal_day_cells
  where "configId" = p_config_id
    and user_id = auth.uid()
    and "classification" <> 'outside'
  group by yr, mo
  order by yr, mo;
$$;

-- =====================================================================
-- 6. CONVENIENCE VIEWS (backward-compatible with v7)
-- =====================================================================

create or replace view public.v_timetable_full
with (security_invoker = true) as
select
  tt.id,
  tt.user_id,
  tt."programId",
  tt."programName",
  tt."semester",
  tt."division",
  tt."day",
  tt."period",
  tt."courseId",
  tt."code",
  c."title" as "courseTitle",
  tt."facultyId",
  tt."facultyName",
  tt."room"
from public.timetable tt
left join public.courses c on c.id = tt."courseId";

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
-- 7. STORAGE — "syllabi" bucket + policies
-- =====================================================================
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
-- Done.
-- =====================================================================

-- =====================================================================
-- IN-PLACE MIGRATION (v7 → v8, no data loss for existing tables)
-- If you already have a v7 database and want to KEEP existing data,
-- do NOT run the clean-slate script above. Run only this block:
-- =====================================================================
/*
create extension if not exists pgcrypto;

create table if not exists public.cal_configs (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  "academicYearId"    uuid references public.academic_years(id) on delete cascade,
  "academicYearLabel" text not null default '',
  "semesterLabel"     text not null default '',
  "semesterType"      text not null default 'odd'
                         check ("semesterType" in ('odd','even')),
  "startDate"         date not null default current_date,
  "endDate"           date not null default current_date + interval '5 months',
  "examStartDate"     date,
  "workingDaysTarget" integer not null default 90 check ("workingDaysTarget" > 0),
  "lecturesPerDay"    integer not null default 6 check ("lecturesPerDay" > 0 and "lecturesPerDay" <= 12),
  "weekendRule"       text not null default 'sunday_only' check ("weekendRule" in ('sunday_only','sat_sun')),
  "institutionName"   text not null default '',
  "university"        text not null default '',
  "regulation"        text not null default '',
  "isApproved"        boolean not null default false,
  "aiOutput"          text not null default '',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint cal_configs_unique unique (user_id, "academicYearId", "semesterType")
);

create table if not exists public.cal_events (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  "configId"  uuid not null references public.cal_configs(id) on delete cascade,
  "date"      date not null,
  "name"      text not null default '',
  "type"      text not null default 'holiday' check ("type" in ('holiday','event','test','exam')),
  "remarks"   text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint cal_events_config_date_name_unique unique ("configId", "date", "name")
);

create table if not exists public.cal_day_cells (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  "configId"       uuid not null references public.cal_configs(id) on delete cascade,
  "date"           date not null,
  "classification" text not null default 'working'
                      check ("classification" in ('working','holiday','test','event','exam','sunday','outside')),
  "eventId"        uuid references public.cal_events(id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint cal_day_cells_config_date_unique unique ("configId", "date")
);

create table if not exists public.cal_approvals (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  "configId"   uuid not null references public.cal_configs(id) on delete cascade,
  "approvedAt" timestamptz not null default now(),
  "approvedBy" text not null default '',
  "remarks"    text not null default '',
  created_at   timestamptz not null default now()
);

-- Indexes
create index if not exists idx_cal_configs_user    on public.cal_configs(user_id);
create index if not exists idx_cal_configs_year    on public.cal_configs("academicYearId");
create index if not exists idx_cal_events_user     on public.cal_events(user_id);
create index if not exists idx_cal_events_config   on public.cal_events("configId");
create index if not exists idx_cal_events_date     on public.cal_events("date");
create index if not exists idx_cal_day_cells_user  on public.cal_day_cells(user_id);
create index if not exists idx_cal_day_cells_config on public.cal_day_cells("configId");
create index if not exists idx_cal_day_cells_date  on public.cal_day_cells("date");
create index if not exists idx_cal_approvals_user  on public.cal_approvals(user_id);
create index if not exists idx_cal_approvals_config on public.cal_approvals("configId");

-- Triggers (reuse existing set_owner function from v7)
create trigger trg_cal_configs_set_owner    before insert on public.cal_configs    for each row execute function public.set_owner_on_insert();
create trigger trg_cal_configs_touch        before update on public.cal_configs    for each row execute function public.touch_and_lock_owner();
create trigger trg_cal_events_set_owner     before insert on public.cal_events     for each row execute function public.set_owner_on_insert();
create trigger trg_cal_events_touch         before update on public.cal_events     for each row execute function public.touch_and_lock_owner();
create trigger trg_cal_day_cells_set_owner  before insert on public.cal_day_cells  for each row execute function public.set_owner_on_insert();
create trigger trg_cal_approvals_set_owner  before insert on public.cal_approvals  for each row execute function public.set_owner_on_insert();

-- RLS
alter table public.cal_configs     enable row level security;
alter table public.cal_events      enable row level security;
alter table public.cal_day_cells   enable row level security;
alter table public.cal_approvals   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['cal_configs','cal_events','cal_day_cells','cal_approvals'] loop
    execute format('create policy "select own %1$s" on public.%1$s for select using (user_id = auth.uid())', t);
    execute format('create policy "insert own %1$s" on public.%1$s for insert with check (user_id = auth.uid())', t);
    execute format('create policy "update own %1$s" on public.%1$s for update using (user_id = auth.uid()) with check (user_id = auth.uid())', t);
    execute format('create policy "delete own %1$s" on public.%1$s for delete using (user_id = auth.uid())', t);
  end loop;
end $$;

-- Approval sync trigger
create or replace function public.sync_cal_config_approval()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.cal_configs set "isApproved" = true, updated_at = now() where id = new."configId";
  return new;
end; $$;
create trigger trg_cal_approvals_sync after insert on public.cal_approvals for each row execute function public.sync_cal_config_approval();

-- RPCs: paste the three functions (upsert_cal_config, regenerate_cal_day_cells,
-- cal_working_day_summary) from section 5 above.
*/
