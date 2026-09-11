-- ============================================================
--  마이그레이션: 관리자 회원 닉네임 변경 RPC
--  Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run (여러 번 실행해도 안전).
--
--  관리자 > 가입자 탭에서 회원 닉네임을 변경. players.name 갱신 +
--  과거 플레이기록에 비정규화 저장된 player_name(회원 기록)도 함께 갱신해
--  기존 기록의 표시 이름까지 새 닉네임으로 반영. (후기 작성자명은 players
--  테이블을 조인하므로 자동 반영됨.)
-- ============================================================

create or replace function public.admin_rename_player(
  p_player_id text, p_pin text, p_target_id text, p_new_name text)
returns json
language plpgsql security definer
set search_path = public, extensions
as $$
declare v_name text := btrim(p_new_name);
begin
  perform public._verify_admin(p_player_id, p_pin);
  if v_name = '' then raise exception '닉네임을 입력하세요.'; end if;
  if length(v_name) > 20 then raise exception '닉네임은 20자 이하로 입력하세요.'; end if;
  if not exists (select 1 from public.players where player_id = p_target_id) then
    raise exception '회원을 찾을 수 없습니다.'; end if;
  if exists (select 1 from public.players where btrim(name) = v_name and player_id <> p_target_id) then
    raise exception '이미 사용 중인 닉네임입니다.'; end if;

  update public.players set name = v_name where player_id = p_target_id;
  -- 과거 플레이기록의 표시 이름(회원 기록만) 갱신
  update public.playlogs set player_name = v_name where player_id = p_target_id;

  return json_build_object('player_id', p_target_id, 'name', v_name);
end $$;

grant execute on function public.admin_rename_player(text, text, text, text) to anon;
