-- ============================================================
--  마이그레이션: 게임 등록자 본인이 직접 게임 정보 수정 가능
--  Supabase 대시보드 → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전).
--
--  1) get_games: 응답에 created_by 추가 → 프론트가 '등록자 본인'을 판별해
--     게임 카드 우측 상단 연필(수정) 버튼을 노출한다.
--  2) update_game: 기존 '관리자만' → '관리자 또는 그 게임을 등록한 본인'.
-- ============================================================

-- 1) get_games 에 created_by 포함
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
    'playtime_min', g.playtime_min, 'weight', g.weight,
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

-- 2) update_game: 관리자 또는 등록자 본인 허용
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
    playtime_min = case when p_payload ? 'playtime_min' then nullif(p_payload->>'playtime_min','')::numeric else playtime_min end,
    weight       = case when p_payload ? 'weight'       then nullif(p_payload->>'weight','')::numeric       else weight end,
    summary_kr = coalesce(p_payload->>'summary_kr', summary_kr),
    image_url  = coalesce(p_payload->>'image_url', image_url)
  where game_id = v_gid;

  return json_build_object('game_id', v_gid, 'updated', true);
end $$;
