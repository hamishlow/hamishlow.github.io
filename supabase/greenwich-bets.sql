-- =========================================================
-- Stumble Bookies: Greenwich Grind betting
-- Paste this whole file into Supabase > SQL Editor and click Run.
-- Safe to run once on a new project.
-- =========================================================

create extension if not exists pgcrypto with schema extensions;

-- One row per bet market. To settle a market, set result to
-- 'a' (option_a won), 'b' (option_b won) or 'void' (refund everyone).
create table markets (
  id         text primary key,
  title      text not null,
  option_a   text not null,
  option_b   text not null,
  closes_at  timestamptz not null,
  result     text check (result in ('a', 'b', 'void')),
  sort       int not null default 0
);

-- Bettors. The PIN is stored hashed and this table is never readable from the website.
create table players (
  name        text primary key,
  pin_hash    text not null,
  created_at  timestamptz not null default now()
);
create unique index players_name_lower on players (lower(name));

create table bets (
  id         bigint generated always as identity primary key,
  player     text not null references players (name),
  market_id  text not null references markets (id),
  pick       text not null check (pick in ('a', 'b')),
  stake      int  not null check (stake > 0),
  placed_at  timestamptz not null default now()
);

-- Row level security: the website can read markets and bets, and nothing else.
-- All writes go through place_bet() below, which enforces the rules.
alter table markets enable row level security;
alter table players enable row level security;
alter table bets    enable row level security;
create policy "public can read markets" on markets for select using (true);
create policy "public can read bets"    on bets    for select using (true);
-- Newer Supabase projects don't grant table access to the website automatically.
grant select on markets, bets to anon, authenticated;

-- Place a bet. Creates the player on their first bet (name + 4-digit PIN),
-- checks the PIN after that, and stops anyone staking more than 100 in total.
create or replace function place_bet(p_name text, p_pin text, p_market text, p_pick text, p_stake int)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name   text := btrim(p_name);
  v_player players;
  v_market markets;
  v_staked int;
begin
  if v_name is null or length(v_name) < 2 or length(v_name) > 30 then
    raise exception 'Enter a name between 2 and 30 characters.';
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception 'Your PIN must be 4 digits.';
  end if;

  select * into v_player from players where lower(name) = lower(v_name) for update;
  if not found then
    insert into players (name, pin_hash)
    values (v_name, crypt(p_pin, gen_salt('bf')))
    returning * into v_player;
  elsif v_player.pin_hash <> crypt(p_pin, v_player.pin_hash) then
    raise exception 'Wrong PIN for %.', v_player.name;
  end if;

  select * into v_market from markets where id = p_market;
  if not found then
    raise exception 'That bet does not exist.';
  end if;
  if v_market.result is not null or now() >= v_market.closes_at then
    raise exception 'Betting on this has closed.';
  end if;
  if p_pick is null or p_pick not in ('a', 'b') then
    raise exception 'Pick a side.';
  end if;
  if p_stake is null or p_stake < 1 then
    raise exception 'Stake at least 1 Stumble Pound.';
  end if;

  select coalesce(sum(stake), 0) into v_staked from bets where player = v_player.name;
  if v_staked + p_stake > 100 then
    raise exception 'You only have % Stumble Pounds left.', 100 - v_staked;
  end if;

  insert into bets (player, market_id, pick, stake)
  values (v_player.name, p_market, p_pick, p_stake);

  return json_build_object('player', v_player.name, 'left', 100 - v_staked - p_stake);
end;
$$;

-- The two opening markets. Betting closes at the 9am start (London time = UTC in November).
insert into markets (id, title, option_a, option_b, closes_at, sort) values
  ('ben-hamish', 'Ben vs Hamish: who wins the decider?', 'Ben',  'Hamish', '2026-11-28 09:00:00+00', 1),
  ('fin-ani',    'Fin vs Ani: who finishes ahead?',      'Fin',  'Ani',    '2026-11-28 09:00:00+00', 2);
