-- ============================================================
--  마이그레이션: (1) 게임 최소/최대 플레이타임  (2) 플레이 순위(rank) 컬럼
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run (여러 번 실행해도 안전).
--
--  (1) games.playtime_min(단일) → min_playtime / max_playtime 로 확장.
--      기존 값은 max_playtime(최대 플레이타임)으로 이관. 표시는 "30~60분".
--  (2) playlogs.rank 컬럼 추가(선택 입력). add_play/update_play/get_plays가
--      rank를 함께 저장·반환하도록 함(프론트 UI는 추후).
-- ============================================================

-- ---- 컬럼 추가 + 데이터 이관 ----
alter table public.games add column if not exists min_playtime numeric;
alter table public.games add column if not exists max_playtime numeric;
update public.games set max_playtime = playtime_min
 where max_playtime is null and playtime_min is not null;

alter table public.playlogs add column if not exists rank numeric;

-- ---- get_games: min/max playtime 포함 ----
create or replace function public.get_games()
returns json
language sql stable security definer
set search_path = public
as $$
  with rt as (
    select game_id,
           round(avg(rating) filter (where rating is not null)::numeric, 1) as club_rating,
           count(*) filter (where rating is not null) as rating_count,
           count(*) filter (where review is not null and btrim(review) <> '') as review_count
    from public.ratings group by game_id
  ),
  pc as (
    select game_id, count(distinct session_id) as play_count
    from public.playlogs group by game_id
  )
  select coalesce(json_agg(json_build_object(
    'game_id', g.game_id, 'name_kr', g.name_kr, 'name_en', g.name_en,
    'category', g.category, 'min_players', g.min_players, 'max_players', g.max_players,
    'playtime_min', g.playtime_min, 'min_playtime', g.min_playtime, 'max_playtime', g.max_playtime,
    'weight', g.weight,
    'summary_kr', g.summary_kr, 'image_url', g.image_url, 'source', g.source,
    'created_by', g.created_by,
    'club_rating', rt.club_rating, 'rating_count', coalesce(rt.rating_count, 0),
    'review_count', coalesce(rt.review_count, 0),
    'play_count', coalesce(pc.play_count, 0)
  ) order by g.game_id), '[]'::json)
  from public.games g
  left join rt on rt.game_id = g.game_id
  left join pc on pc.game_id = g.game_id;
$$;

-- ---- add_game: min/max playtime 저장 ----
create or replace function public.add_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_id text; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  if btrim(coalesce(p_payload->>'name_kr','')) = '' then raise exception '한글 게임명을 입력하세요.'; end if;
  if exists (select 1 from public.games
             where regexp_replace(lower(btrim(name_kr)), '\s+', '', 'g')
                 = regexp_replace(lower(btrim(coalesce(p_payload->>'name_kr',''))), '\s+', '', 'g')) then
    raise exception '이미 등록된 게임명입니다.'; end if;
  v_id := public._next_id('G', 3, 'games', 'game_id');

  insert into public.games(
    game_id, name_kr, name_en, category,
    min_players, max_players, min_playtime, max_playtime, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id,
    btrim(coalesce(p_payload->>'name_kr','')), coalesce(p_payload->>'name_en',''),
    coalesce(p_payload->>'category',''),
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'min_playtime','')::numeric,
    nullif(p_payload->>'max_playtime','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );

  return json_build_object('game_id', v_id, 'name_kr', coalesce(p_payload->>'name_kr',''), 'source', 'manual');
end $$;

-- ---- update_game: 관리자/등록자 권한 + min/max playtime 갱신 ----
create or replace function public.update_game(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_role text; v_gid text; v_created text; v_exists boolean;
begin
  perform public._verify(p_player_id, p_pin);
  select role into v_role from public.players where player_id = p_player_id;

  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception 'game_id가 필요합니다.'; end if;
  select (count(*) > 0), max(created_by) into v_exists, v_created
    from public.games where game_id = v_gid;
  if not v_exists then raise exception '게임을 찾을 수 없습니다.'; end if;
  if coalesce(v_role,'') <> 'admin' and coalesce(v_created,'') <> p_player_id then
    raise exception '본인이 등록한 게임 또는 관리자만 수정할 수 있습니다.'; end if;

  update public.games set
    name_kr   = coalesce(p_payload->>'name_kr', name_kr),
    name_en   = coalesce(p_payload->>'name_en', name_en),
    category  = coalesce(p_payload->>'category', category),
    min_players  = case when p_payload ? 'min_players'  then nullif(p_payload->>'min_players','')::numeric  else min_players end,
    max_players  = case when p_payload ? 'max_players'  then nullif(p_payload->>'max_players','')::numeric  else max_players end,
    min_playtime = case when p_payload ? 'min_playtime' then nullif(p_payload->>'min_playtime','')::numeric else min_playtime end,
    max_playtime = case when p_payload ? 'max_playtime' then nullif(p_payload->>'max_playtime','')::numeric else max_playtime end,
    weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
    summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
    image_url  = coalesce(p_payload->>'image_url', image_url)
  where game_id = v_gid;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;

-- ---- add_play: 참가자별 rank 저장 ----
create or replace function public.add_play(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_sid text; v_maxrec int; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
  v_date text; v_dur numeric; v_gid text; v_part jsonb; v_count int;
begin
  perform public._verify(p_player_id, p_pin);
  v_gid := p_payload->>'game_id';
  if coalesce(v_gid,'') = '' then raise exception '게임을 선택하세요.'; end if;
  if jsonb_typeof(p_payload->'participants') <> 'array'
     or jsonb_array_length(p_payload->'participants') = 0 then
    raise exception '참가자가 없습니다.'; end if;

  v_sid := public._next_id('S', 4, 'playlogs', 'session_id');
  select coalesce(max((substring(record_id from '^R([0-9]+)$'))::int), 0)
    into v_maxrec from public.playlogs;
  v_date := coalesce(nullif(p_payload->>'play_date',''), to_char(now(),'YYYY-MM-DD'));
  v_dur  := nullif(p_payload->>'duration_min','')::numeric;

  for v_part in select * from jsonb_array_elements(p_payload->'participants') loop
    v_maxrec := v_maxrec + 1;
    insert into public.playlogs(
      record_id, session_id, play_date, game_id, duration_min,
      player_id, player_name, score, is_win, rank, created_by, created_at)
    values(
      'R' || lpad(v_maxrec::text, 5, '0'), v_sid, v_date, v_gid, v_dur,
      nullif(v_part->>'player_id',''),
      coalesce(v_part->>'player_name',''),
      nullif(v_part->>'score','')::numeric,
      coalesce((v_part->>'is_win')::boolean, false),
      nullif(v_part->>'rank','')::numeric,
      p_player_id, v_now
    );
  end loop;

  v_count := jsonb_array_length(p_payload->'participants');
  return json_build_object('session_id', v_sid, 'count', v_count);
end $$;

-- ---- update_play: full-replace 시 참가자별 rank 저장 ----
create or replace function public.update_play(p_player_id text, p_pin text, p_payload jsonb)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  v_auth public.players;
  v_sid text; v_created text; v_gid text; v_olddate text;
  v_date text; v_dur numeric; v_cnt int; v_row jsonb; v_part jsonb;
  v_maxrec int; v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  v_auth := public._verify(p_player_id, p_pin);
  v_sid := p_payload->>'session_id';
  if coalesce(v_sid,'') = '' then raise exception 'session_id가 필요합니다.'; end if;

  select created_by, game_id, play_date
    into v_created, v_gid, v_olddate
    from public.playlogs where session_id = v_sid order by record_id limit 1;
  if v_created is null then raise exception '기록을 찾을 수 없습니다.'; end if;
  if v_created <> p_player_id and coalesce(v_auth.role,'') <> 'admin' then
    raise exception '본인이 입력한 기록만 수정할 수 있습니다.'; end if;

  v_date := nullif(p_payload->>'play_date','');
  v_dur  := nullif(p_payload->>'duration_min','')::numeric;

  if jsonb_typeof(p_payload->'participants') = 'array' then
    if jsonb_array_length(p_payload->'participants') = 0 then
      raise exception '참가자가 없습니다.'; end if;

    delete from public.playlogs where session_id = v_sid;

    select coalesce(max((substring(record_id from '^R([0-9]+)$'))::int), 0)
      into v_maxrec from public.playlogs;

    for v_part in select * from jsonb_array_elements(p_payload->'participants') loop
      v_maxrec := v_maxrec + 1;
      insert into public.playlogs(
        record_id, session_id, play_date, game_id, duration_min,
        player_id, player_name, score, is_win, rank, created_by, created_at)
      values(
        'R' || lpad(v_maxrec::text, 5, '0'), v_sid,
        coalesce(v_date, v_olddate), v_gid, v_dur,
        nullif(v_part->>'player_id',''),
        coalesce(v_part->>'player_name',''),
        nullif(v_part->>'score','')::numeric,
        coalesce((v_part->>'is_win')::boolean, false),
        nullif(v_part->>'rank','')::numeric,
        v_created, v_now
      );
    end loop;

    select count(*) into v_cnt from public.playlogs where session_id = v_sid;
    return json_build_object('session_id', v_sid, 'updated', v_cnt, 'mode', 'replace');
  end if;

  update public.playlogs
     set play_date = coalesce(v_date, play_date),
         duration_min = v_dur
   where session_id = v_sid;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'rows','[]'::jsonb)) loop
    update public.playlogs
       set score  = nullif(v_row->>'score','')::numeric,
           is_win = coalesce((v_row->>'is_win')::boolean, false)
     where record_id = v_row->>'record_id' and session_id = v_sid;
  end loop;

  select count(*) into v_cnt from public.playlogs where session_id = v_sid;
  return json_build_object('session_id', v_sid, 'updated', v_cnt, 'mode', 'rows');
end $$;

-- ---- get_plays: 참가자 rank 반환 ----
create or replace function public.get_plays()
returns json
language sql stable security definer
set search_path = public
as $$
  with parts as (
    select p.session_id, p.record_id,
      json_build_object(
        'record_id', p.record_id,
        'player_id', p.player_id,
        'name', coalesce(nullif(btrim(p.player_name), ''), pl.name, p.player_id),
        'is_guest', (p.player_id is null or p.player_id = '' or pl.player_id is null),
        'score', p.score,
        'is_win', coalesce(p.is_win, false),
        'rank', p.rank
      ) as participant
    from public.playlogs p
    left join public.players pl on pl.player_id = p.player_id
  ),
  sess as (
    select s.session_id, s.play_date, s.game_id, s.duration_min, s.created_by,
           g.name_kr, g.name_en, g.image_url
    from (
      select distinct on (session_id)
             session_id, play_date, game_id, duration_min, created_by
      from public.playlogs
      order by session_id, record_id
    ) s
    left join public.games g on g.game_id = s.game_id
  )
  select coalesce(json_agg(json_build_object(
    'session_id',   se.session_id,
    'play_date',    se.play_date,
    'game_id',      se.game_id,
    'game_name',    coalesce(se.name_kr, se.name_en, '(알 수 없는 게임)'),
    'game_image',   coalesce(se.image_url, ''),
    'duration_min', se.duration_min,
    'created_by',   coalesce(se.created_by, ''),
    'participants', (
      select coalesce(json_agg(pa.participant order by pa.record_id), '[]'::json)
      from parts pa where pa.session_id = se.session_id
    )
  ) order by se.play_date desc, se.session_id desc), '[]'::json)
  from sess se;
$$;
