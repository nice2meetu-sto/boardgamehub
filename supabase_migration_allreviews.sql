-- ============================================================
--  마이그레이션: 전체 후기 조회 RPC (후기 탭용)
--  Supabase 대시보드 → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전).
--
--  모든 게임의 후기를 최신순으로 반환. 각 후기에 작성자 닉네임 + 게임명 +
--  게임 이미지 + 시간(updated_at)을 함께 담아 채팅 UI에서 바로 렌더.
-- ============================================================

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
    'updated_at',  r.updated_at
  ) order by r.updated_at desc nulls last), '[]'::json)
  from public.ratings r
  left join public.players pl on pl.player_id = r.player_id
  left join public.games   g  on g.game_id   = r.game_id
  where r.review is not null and btrim(r.review) <> '';
$$;

grant execute on function public.get_all_reviews() to anon;
