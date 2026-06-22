-- Overture scout-phase schema: the three tables the event scout + ranker need.
-- Emailing tables (contacts, drafts, sends, events, variants) are deferred until we
-- build emailing, per the plan's "model is open to revision during the build."
--
-- RLS is enabled on every table with NO policies, so the public anon key cannot
-- read or write any of this. All access is server-side via the service-role key.

-- ---------------------------------------------------------------------------
-- Enums. The classification values mirror the ranker's Candidate type
-- (src/lib/ranker.ts) so the scout's output maps straight onto a prospect row.
-- ---------------------------------------------------------------------------
create type discipline as enum (
  'dance', 'opera', 'theater', 'choral', 'music', 'band', 'comedy', 'other'
);

create type production_type as enum ('self', 'agency', 'unknown');

create type profile_match as enum ('strong', 'neutral', 'weak');

create type coverage_likelihood as enum (
  'likely_uncovered', 'unknown', 'likely_covered'
);

create type prior_relationship as enum ('booked', 'contacted', 'none');

create type prospect_tier as enum ('high', 'longshot');

create type prospect_status as enum (
  'new', 'queued', 'approved', 'sent', 'replied', 'booked', 'lost', 'dismissed'
);

create type dismiss_reason as enum (
  'date_conflict', 'day_doesnt_work', 'not_interested', 'already_booked', 'duplicate'
);

-- updated_at maintenance, shared by any table that wants it.
create function set_updated_at() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- ---------------------------------------------------------------------------
-- history: the imported booking log (Downloads/Lead Booking sources CSV).
-- Used for dedup and prior-relationship flagging. Columns mirror the CSV
-- (Name of Group, Date of shoot, Email, Venue, First Contact, Type of Contact,
-- Status); raw_row keeps the original line so nothing is lost on import.
-- ---------------------------------------------------------------------------
create table history (
  id            uuid primary key default gen_random_uuid(),
  group_name    text not null,
  shoot_date    date,
  email         text,
  venue         text,
  first_contact text,
  contact_type  text,
  status        text,
  raw_row       jsonb,
  created_at    timestamptz not null default now()
);

create index history_group_name_idx on history (lower(group_name));
create index history_email_idx on history (lower(email));

alter table history enable row level security;

-- ---------------------------------------------------------------------------
-- blocked_dates: days Dan dismissed as "day does not work," so they never
-- resurface. One row per blocked date.
-- ---------------------------------------------------------------------------
create table blocked_dates (
  id           uuid primary key default gen_random_uuid(),
  blocked_date date not null unique,
  reason       text,
  created_at   timestamptz not null default now()
);

alter table blocked_dates enable row level security;

-- ---------------------------------------------------------------------------
-- prospects: every discovered performance. Stores both the scout's raw
-- classifications (the ranker's inputs) and the ranker's outputs (score, tier,
-- reason), so a prospect can be re-scored if the weights change without
-- re-scouting. geography_note / travel_fee_likely capture the v1 Claude travel
-- estimate; prior_history_id links to the matched booking-log row when found.
-- ---------------------------------------------------------------------------
create table prospects (
  id                  uuid primary key default gen_random_uuid(),

  -- who / what / where / when
  group_name          text not null,
  discipline          discipline not null default 'other',
  venue               text,
  performance_date    date,
  source_listing_url  text,
  website_url         text,

  -- ranker inputs (the scout's classification)
  reachable           boolean not null default true,
  prior_relationship  prior_relationship not null default 'none',
  production          production_type not null default 'unknown',
  profile             profile_match not null default 'neutral',
  coverage            coverage_likelihood not null default 'unknown',

  -- ranker outputs
  fit_score           integer,
  tier                prospect_tier,
  fit_reason          text,

  -- geography / travel (v1 Claude estimate)
  geography_note      text,
  travel_fee_likely   boolean,

  -- pipeline state
  status              prospect_status not null default 'new',
  dismiss_reason      dismiss_reason,
  prior_history_id    uuid references history (id) on delete set null,

  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- The queue sorts by performance date ascending, fit score as the tiebreaker.
create index prospects_queue_order_idx
  on prospects (performance_date asc, fit_score desc);
create index prospects_status_idx on prospects (status);
create index prospects_group_name_idx on prospects (lower(group_name));

create trigger prospects_set_updated_at
  before update on prospects
  for each row execute function set_updated_at();

alter table prospects enable row level security;
