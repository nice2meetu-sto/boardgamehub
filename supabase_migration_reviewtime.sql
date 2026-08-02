-- ============================================================
--  마이그레이션: 후기 시간 분리 (review_updated_at)
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run (여러 번 실행해도 안전).
--
--  문제: ratings.updated_at 을 후기·별점·메모가 공유해서, 별점/메모만 수정해도
--        후기 시간이 최신으로 바뀌어 후기 탭에서 위로 올라옴.
--  해결: 후기 전용 시간 컬럼 review_updated_at 추가 → save_review 에서만 갱신.
--        후기 조회(get_reviews / get_all_reviews)는 review_updated_at 을 우선 사용
--        (없으면 기존 updated_at 으로 폴백)하고, 그 값을 'updated_at' 키로 반환
--        → 프론트 코드는 수정 불필요.
-- ============================================================

-- ---- 컬럼 추가 + 기존 후기 백필(현재 updated_at 을 후기 시간 초기값으로) ----
alter table public.ratings add column if not exists review_updated_at text;
update public.ratings
   set review_updated_at = updated_at
 where review_updated_at is null
   and review is not null and btrim(review) <> '';

-- ---- save_review: 후기 저장 시 review_updated_at 갱신(후기 전용 시간) ----
create or replace function public.save_review(
  p_player_id text, p_pin text, p_game_id text, p_review text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_now text := to_char(now(), 'YYYY-MM-DD HH24:MI:SS');
begin
  perform public._verify(p_player_id, p_pin);
  insert into public.ratings(player_id, game_id, review, review_updated_at, updated_at)
  values (p_player_id, p_game_id, coalesce(p_review, ''), v_now, v_now)
  on conflict (player_id, game_id) do update
    set review = excluded.review,
        review_updated_at = excluded.review_updated_at,
        updated_at = excluded.updated_at;
  return json_build_object('player_id', p_player_id, 'game_id', p_game_id, 'review', coalesce(p_review, ''));
end $$;

-- ---- get_reviews: 후기 시간 = review_updated_at(없으면 updated_at) ----
create or replace function public.get_reviews(p_game_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'name', p.name, 'review', r.review,
    'updated_at', coalesce(r.review_updated_at, r.updated_at)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  join public.players p on p.player_id = r.player_id
  where r.game_id = p_game_id and r.review is not null and btrim(r.review) <> '';
$$;

-- ---- get_all_reviews: 후기 탭(채팅 UI)도 후기 시간 기준 ----
create or replace function public.get_all_reviews()
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'player_id',   r.player_id,
    'player_name', pl.name,
    'game_id',     r.game_id,
    'game_name',   coalesce(g.name_kr, g.name_en, '(알 수 없는 게임)'),
    'game_image',  coalesce(g.image_url, ''),
    'review',      r.review,
    'rating',      r.rating,
    'updated_at',  coalesce(r.review_updated_at, r.updated_at)
  ) order by coalesce(r.review_updated_at, r.updated_at) desc nulls last), '[]'::json)
  from public.ratings r
  left join public.players pl on pl.player_id = r.player_id
  left join public.games   g  on g.game_id   = r.game_id
  where r.review is not null and btrim(r.review) <> '';
$$;

grant execute on function public.get_reviews(text)   to anon;
grant execute on function public.get_all_reviews()   to anon;
