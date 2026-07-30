-- ============================================================
--  마이그레이션: 게임 [베스트 인원] 컬럼 추가
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run (여러 번 실행해도 안전).
--
--  games.best_players(권장/베스트 인원) 추가. "4" 또는 "4-5" 같은 자유 텍스트 저장.
--  get_games / add_game / update_game 가 best_players 를 함께 처리하도록 갱신.
-- ============================================================

-- ---- 컬럼 추가(text). 이전에 numeric으로 만든 경우 text로 변환(여러 번 실행 안전) ----
alter table public.games add column if not exists best_players text;
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'games'
      and column_name = 'best_players' and data_type <> 'text'
  ) then
    alter table public.games alter column best_players type text using best_players::text;
  end if;
end $$;

-- ---- get_games: best_players 포함 ----
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
    'best_players', g.best_players,
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

-- ---- add_game: best_players 저장 ----
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
    min_players, max_players, best_players, min_playtime, max_playtime, weight,
    summary_kr, image_url, source, created_by, created_at)
  values(
    v_id,
    btrim(coalesce(p_payload->>'name_kr','')), coalesce(p_payload->>'name_en',''),
    coalesce(p_payload->>'category',''),
    nullif(p_payload->>'min_players','')::numeric,
    nullif(p_payload->>'max_players','')::numeric,
    nullif(p_payload->>'best_players',''),
    nullif(p_payload->>'min_playtime','')::numeric,
    nullif(p_payload->>'max_playtime','')::numeric,
    nullif(p_payload->>'weight','')::numeric,
    coalesce(p_payload->>'summary_kr',''), coalesce(p_payload->>'image_url',''),
    'manual', p_player_id, v_now
  );

  return json_build_object('game_id', v_id, 'name_kr', coalesce(p_payload->>'name_kr',''), 'source', 'manual');
end $$;

-- ---- update_game: best_players 갱신 ----
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
    best_players = case when p_payload ? 'best_players' then nullif(p_payload->>'best_players','') else best_players end,
    min_playtime = case when p_payload ? 'min_playtime' then nullif(p_payload->>'min_playtime','')::numeric else min_playtime end,
    max_playtime = case when p_payload ? 'max_playtime' then nullif(p_payload->>'max_playtime','')::numeric else max_playtime end,
    weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
    summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
    image_url  = coalesce(p_payload->>'image_url', image_url)
  where game_id = v_gid;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;
