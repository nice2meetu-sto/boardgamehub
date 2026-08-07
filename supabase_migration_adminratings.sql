-- ============================================================
--  마이그레이션: 관리자용 게임별 회원 평점 조회 RPC
--  Supabase 대시보드 → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전).
--
--  관리자만: 어느 회원이 어느 게임에 몇 점 줬는지 + 후기 내용까지 전체 반환.
--  호출자(p_player_id)가 admin 이 아니면 빈 배열([]) 반환.
-- ============================================================

create or replace function public.get_all_ratings(p_player_id text)
returns json
language sql stable security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object(
    'game_id',     r.game_id,
    'game_name',   coalesce(g.name_kr, g.name_en, r.game_id),
    'game_image',  coalesce(g.image_url, ''),
    'player_name', coalesce(pl.name, r.player_id),
    'rating',      r.rating,
    'review',      r.review
  )), '[]'::json)
  from public.ratings r
  left join public.players pl on pl.player_id = r.player_id
  left join public.games   g  on g.game_id   = r.game_id
  where (r.rating is not null or (r.review is not null and btrim(r.review) <> ''))
    and exists (select 1 from public.players a
                 where a.player_id = p_player_id and a.role = 'admin');
$$;

grant execute on function public.get_all_ratings(text) to anon;
