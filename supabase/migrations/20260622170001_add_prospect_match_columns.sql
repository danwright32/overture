-- Repeat-client match results for prospects. A confident Downbeat client match
-- fills downbeat_client_id + matched_client_name. A fuzzy "possible" match is
-- source-tagged (downbeat_client or history) for Dan to confirm in the queue.
alter table prospects
  add column downbeat_client_id  uuid,
  add column matched_client_name text,
  add column possible_match_source text
    check (possible_match_source in ('downbeat_client', 'history')),
  add column possible_match_ref  uuid,
  add column possible_match_name text;
