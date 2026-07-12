-- ============================================================
--  마이그레이션: 후기(공개) / 게임메모(개인) 분리
--  기존 DB에 이미 스키마가 적용된 상태에서 SQL Editor에 붙여넣고 Run.
--  (여러 번 실행해도 안전)
--
--  변경 요약
--   - ratings 에 review(공개 후기) 컬럼 추가. 기존 memo 는 개인 메모로 유지.
--   - save_rating: 평점 + 후기(review) 저장 (memo 는 건드리지 않음)
--   - save_memo(신규): 개인 게임메모 저장
--   - get_reviews(신규): 게임별 공개 후기 목록(닉네임 + 후기)
--   - get_my_ratings: review, memo 둘 다 반환
-- ============================================================

alter table public.ratings add column if not exists review text;

-- save_rating: 파라미터명 변경(p_memo→p_review) 위해 drop 후 재생성
drop function if exists public.save_rating(text, text, text, numeric, text);
create or replace function public.save_rating(
  p_player_id text, p_pin text, p_game_id text, p_rating numeric, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  if p_rating is null or p_rating < 1 or p_rating > 10 then
    raise exception '평점은 1~10 사이여야 합니다.'; end if;

  insert into public.ratings(player_id, game_id, rating, review, updated_at)
  values (p_player_id, p_game_id, p_rating, coalesce(p_review, ''), v_now)
  on conflict (player_id, game_id) do update
    set rating = excluded.rating, review = excluded.review, updated_at = excluded.updated_at;

  return json_build_object('player_id', p_player_id, 'game_id', p_game_id,
                           'rating', p_rating, 'review', coalesce(p_review, ''), 'updated_at', v_now);
end $$;

-- save_memo(신규): 개인 게임메모(비공개) 저장. 평점/후기는 건드리지 않음.
create or replace function public.save_memo(
  p_player_id text, p_pin text, p_game_id text, p_memo text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, memo, updated_at)
  values (p_player_id, p_game_id, coalesce(p_memo, ''), v_now)
  on conflict (player_id, game_id) do update
    set memo = excluded.memo, updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'memo', coalesce(p_memo, ''));
end $$;

-- get_reviews(신규): 게임별 공개 후기 목록(닉네임 + 후기), 최신순
create or replace function public.get_reviews(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review, 'updated_at', r.updated_at
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  where r.game_id = p_game_id and r.review is not null and btrim(r.review) <> '';
$$;

-- get_my_ratings: review, memo 둘 다 반환
create or replace function public.get_my_ratings(p_player_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id',    r.game_id,
    'game',       coalesce(g.name_kr, g.name_en, r.game_id),
    'rating',     r.rating,
    'memo',       coalesce(r.memo, ''),
    'review',     coalesce(r.review, ''),
    'updated_at', r.updated_at
  )), '[]'::json)
  from public.ratings r
  left join public.games g on g.game_id = r.game_id
  where r.player_id = p_player_id;
$$;

-- 실행 권한
grant execute on function public.save_rating(text, text, text, numeric, text) to anon;
grant execute on function public.save_memo(text, text, text, text)            to anon;
grant execute on function public.get_reviews(text)                            to anon;
grant execute on function public.get_my_ratings(text)                         to anon;
