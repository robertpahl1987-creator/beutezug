-- =====================================================================
-- Beutezug – Datenbank (Supabase / PostgreSQL)
-- Im Supabase-Dashboard unter "SQL Editor" komplett einfügen und "Run".
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Tabellen ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text not null check (char_length(name) between 2 and 20),
  stars       bigint not null default 0,
  created_at  timestamptz not null default now()
);

create table if not exists public.saves (
  user_id     uuid primary key references public.profiles on delete cascade,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);

create table if not exists public.teams (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 3 and 22),
  flag        int  not null default 0 check (flag between 0 and 7),
  description text not null default '' check (char_length(description) <= 80),
  open        boolean not null default true,
  min_stars   bigint not null default 0,
  leader      uuid references public.profiles on delete set null,
  castle_h    int not null default 0,
  castle_max  int not null default 15,
  castle_lvl  int not null default 1,
  created_at  timestamptz not null default now()
);
create unique index if not exists teams_name_uq on public.teams (lower(name));

create table if not exists public.team_members (
  user_id     uuid primary key references public.profiles on delete cascade,  -- ein Spieler = ein Team
  team_id     uuid not null references public.teams on delete cascade,
  joined_at   timestamptz not null default now()
);
create index if not exists team_members_team on public.team_members (team_id);

create table if not exists public.team_join_requests (
  team_id     uuid references public.teams on delete cascade,
  user_id     uuid references public.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (team_id, user_id)
);

create table if not exists public.team_messages (
  id          bigint generated always as identity primary key,
  team_id     uuid not null references public.teams on delete cascade,
  user_id     uuid references public.profiles on delete set null,
  kind        text not null check (kind in ('msg','req','sys')),
  body        text not null default '' check (char_length(body) <= 200),
  got         int  not null default 0 check (got between 0 and 10),
  collected   boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists team_messages_feed on public.team_messages (team_id, created_at desc);

create table if not exists public.team_help (
  message_id  bigint references public.team_messages on delete cascade,
  helper_id   uuid references public.profiles on delete cascade,
  primary key (message_id, helper_id)
);

-- ---------- Übersicht für die Teamsuche ----------
create or replace view public.team_overview with (security_invoker = on) as
select t.id, t.name, t.flag, t.description, t.open, t.min_stars, t.leader,
       t.castle_h, t.castle_max, t.castle_lvl,
       (select count(*) from public.team_members m where m.team_id = t.id) as member_count,
       (select coalesce(sum(p.stars),0) from public.team_members m
          join public.profiles p on p.id = m.user_id where m.team_id = t.id) as stars
from public.teams t;

-- ---------- Hilfsfunktion ----------
create or replace function public.my_team() returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from team_members where user_id = auth.uid()
$$;

-- ---------- Zugriffsregeln (Row Level Security) ----------
alter table public.profiles           enable row level security;
alter table public.saves              enable row level security;
alter table public.teams              enable row level security;
alter table public.team_members       enable row level security;
alter table public.team_join_requests enable row level security;
alter table public.team_messages      enable row level security;
alter table public.team_help          enable row level security;

drop policy if exists p_profiles_read  on public.profiles;
drop policy if exists p_profiles_ins   on public.profiles;
drop policy if exists p_profiles_upd   on public.profiles;
create policy p_profiles_read on public.profiles for select to authenticated using (true);
create policy p_profiles_ins  on public.profiles for insert to authenticated with check (id = auth.uid());
create policy p_profiles_upd  on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists p_saves_all on public.saves;
create policy p_saves_all on public.saves for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists p_teams_read on public.teams;
drop policy if exists p_teams_upd  on public.teams;
create policy p_teams_read on public.teams for select to authenticated using (true);
create policy p_teams_upd  on public.teams for update to authenticated
  using (leader = auth.uid()) with check (leader = auth.uid());

drop policy if exists p_members_read on public.team_members;
create policy p_members_read on public.team_members for select to authenticated using (true);

drop policy if exists p_joinreq_read on public.team_join_requests;
create policy p_joinreq_read on public.team_join_requests for select to authenticated
  using (user_id = auth.uid() or team_id in (select id from public.teams where leader = auth.uid()));

drop policy if exists p_msg_read on public.team_messages;
drop policy if exists p_msg_ins  on public.team_messages;
create policy p_msg_read on public.team_messages for select to authenticated using (team_id = public.my_team());
create policy p_msg_ins  on public.team_messages for insert to authenticated
  with check (team_id = public.my_team() and user_id = auth.uid()
              and kind in ('msg','req') and got = 0 and collected = false);

drop policy if exists p_help_read on public.team_help;
create policy p_help_read on public.team_help for select to authenticated using (helper_id = auth.uid());

-- ---------- Spiel-Funktionen ----------
create or replace function public.create_team(p_name text, p_flag int, p_desc text, p_open boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if exists (select 1 from team_members where user_id = auth.uid()) then
    raise exception 'Du bist schon in einem Team';
  end if;
  insert into teams (name, flag, description, open, leader)
  values (trim(p_name), coalesce(p_flag,0), coalesce(p_desc,''), coalesce(p_open,true), auth.uid())
  returning id into tid;
  insert into team_members (user_id, team_id) values (auth.uid(), tid);
  insert into team_messages (team_id, kind, body) values (tid, 'sys', 'Team gegründet. Lade deine Freunde ein!');
  return tid;
end $$;

create or replace function public.join_team(p_team uuid)
returns text language plpgsql security definer set search_path = public as $$
declare t teams; cnt int; st bigint; nm text;
begin
  if auth.uid() is null then raise exception 'Nicht angemeldet'; end if;
  if exists (select 1 from team_members where user_id = auth.uid()) then
    raise exception 'Du bist schon in einem Team';
  end if;
  select * into t from teams where id = p_team;
  if not found then raise exception 'Team nicht gefunden'; end if;
  select count(*) into cnt from team_members where team_id = p_team;
  if cnt >= 50 then raise exception 'Das Team ist voll'; end if;
  select stars, name into st, nm from profiles where id = auth.uid();
  if coalesce(st,0) < t.min_stars then raise exception 'Zu wenig Sterne für dieses Team'; end if;
  if t.open then
    insert into team_members (user_id, team_id) values (auth.uid(), p_team);
    delete from team_join_requests where user_id = auth.uid();
    insert into team_messages (team_id, kind, body) values (p_team, 'sys', nm || ' ist dem Team beigetreten.');
    return 'joined';
  end if;
  insert into team_join_requests (team_id, user_id) values (p_team, auth.uid()) on conflict do nothing;
  return 'requested';
end $$;

create or replace function public.answer_join(p_user uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare tid uuid; nm text;
begin
  select id into tid from teams where leader = auth.uid();
  if tid is null then raise exception 'Nur der Anführer darf das'; end if;
  if not exists (select 1 from team_join_requests where team_id = tid and user_id = p_user) then
    raise exception 'Keine offene Anfrage';
  end if;
  delete from team_join_requests where team_id = tid and user_id = p_user;
  if p_accept then
    if exists (select 1 from team_members where user_id = p_user) then raise exception 'Spieler ist schon in einem Team'; end if;
    if (select count(*) from team_members where team_id = tid) >= 50 then raise exception 'Das Team ist voll'; end if;
    insert into team_members (user_id, team_id) values (p_user, tid);
    delete from team_join_requests where user_id = p_user;
    select name into nm from profiles where id = p_user;
    insert into team_messages (team_id, kind, body) values (tid, 'sys', nm || ' wurde ins Team aufgenommen.');
  end if;
end $$;

create or replace function public.leave_team()
returns void language plpgsql security definer set search_path = public as $$
declare tid uuid; nxt uuid; nm text; nn text;
begin
  select team_id into tid from team_members where user_id = auth.uid();
  if tid is null then return; end if;
  select name into nm from profiles where id = auth.uid();
  delete from team_members where user_id = auth.uid();
  if not exists (select 1 from team_members where team_id = tid) then
    delete from teams where id = tid;
    return;
  end if;
  if (select leader from teams where id = tid) = auth.uid() then
    select user_id into nxt from team_members where team_id = tid order by joined_at limit 1;
    update teams set leader = nxt where id = tid;
    select name into nn from profiles where id = nxt;
    insert into team_messages (team_id, kind, body) values (tid, 'sys', nm || ' hat das Team verlassen. Neuer Anführer: ' || nn);
  else
    insert into team_messages (team_id, kind, body) values (tid, 'sys', nm || ' hat das Team verlassen.');
  end if;
end $$;

create or replace function public.kick_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare tid uuid; nm text;
begin
  select id into tid from teams where leader = auth.uid();
  if tid is null then raise exception 'Nur der Anführer darf das'; end if;
  if p_user = auth.uid() then raise exception 'Du kannst dich nicht selbst entfernen'; end if;
  delete from team_members where user_id = p_user and team_id = tid;
  if found then
    select name into nm from profiles where id = p_user;
    insert into team_messages (team_id, kind, body) values (tid, 'sys', nm || ' wurde aus dem Team entfernt.');
  end if;
end $$;

create or replace function public.help_request(p_msg bigint)
returns int language plpgsql security definer set search_path = public as $$
declare m team_messages;
begin
  select * into m from team_messages where id = p_msg for update;
  if not found or m.kind <> 'req' or m.collected then raise exception 'Die Anfrage ist nicht mehr offen'; end if;
  if m.team_id is distinct from my_team() then raise exception 'Das ist nicht dein Team'; end if;
  if m.user_id = auth.uid() then raise exception 'Das ist deine eigene Anfrage'; end if;
  if m.got >= 10 then raise exception 'Die Anfrage ist schon voll'; end if;
  insert into team_help (message_id, helper_id) values (p_msg, auth.uid());
  update team_messages set got = got + 1 where id = p_msg;
  return m.got + 1;
exception when unique_violation then
  raise exception 'Du hast hier schon geholfen';
end $$;

create or replace function public.collect_request(p_msg bigint)
returns int language plpgsql security definer set search_path = public as $$
declare g int;
begin
  update team_messages set collected = true
   where id = p_msg and user_id = auth.uid() and kind = 'req' and not collected
  returning got into g;
  if g is null then raise exception 'Nichts zum Abholen'; end if;
  return g;
end $$;

create or replace function public.castle_add(p_n int)
returns json language plpgsql security definer set search_path = public as $$
declare t teams;
begin
  update teams set castle_h = least(castle_max, castle_h + greatest(0, least(p_n, 3)))
   where id = my_team() returning * into t;
  if t.id is null then raise exception 'Kein Team'; end if;
  if t.castle_h >= t.castle_max then
    update teams set castle_h = 0, castle_lvl = castle_lvl + 1, castle_max = castle_max + 5
     where id = t.id returning * into t;
    insert into team_messages (team_id, kind, body)
    values (t.id, 'sys', 'Team-Schloss Stufe ' || (t.castle_lvl - 1) || ' fertig! Alle bekommen Versuche.');
  end if;
  return json_build_object('h', t.castle_h, 'max', t.castle_max, 'lvl', t.castle_lvl);
end $$;

revoke execute on function public.create_team(text,int,text,boolean), public.join_team(uuid),
  public.answer_join(uuid,boolean), public.leave_team(), public.kick_member(uuid),
  public.help_request(bigint), public.collect_request(bigint), public.castle_add(int) from anon, public;
grant execute on function public.create_team(text,int,text,boolean), public.join_team(uuid),
  public.answer_join(uuid,boolean), public.leave_team(), public.kick_member(uuid),
  public.help_request(bigint), public.collect_request(bigint), public.castle_add(int), public.my_team() to authenticated;
