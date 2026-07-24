-- ============================================================
--  마이그레이션: update_play 참가자 편집 + 게스트→회원 연동 지원
--  Supabase 대시보드 → SQL Editor 에 붙여넣고 Run (여러 번 실행해도 안전).
--
--  변경점: update_play RPC가 payload의 'participants' 배열을 받으면
--   그 세션의 참가자 행 전체를 교체(full-replace)한다.
--   - 참가자 이름/게스트↔회원/점수/승패 편집
--   - 게스트(player_id NULL) → 회원(player_id) 연동
--   세션 id·게임·작성자(created_by)는 보존한다.
--   'participants'가 없으면 기존(rows: 점수/승패만) 동작을 그대로 유지한다.
--
--  권한: 기존과 동일 — 세션 작성자 본인 또는 role='admin'만.
-- ============================================================

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
    -- 참가자 전체 교체(full-replace)
    if jsonb_array_length(p_payload->'participants') = 0 then
      raise exception '참가자가 없습니다.'; end if;

    delete from public.playlogs where session_id = v_sid;

    select coalesce(max((substring(record_id from '^R([0-9]+)$'))::int), 0)
      into v_maxrec from public.playlogs;

    for v_part in select * from jsonb_array_elements(p_payload->'participants') loop
      v_maxrec := v_maxrec + 1;
      insert into public.playlogs(
        record_id, session_id, play_date, game_id, duration_min,
        player_id, player_name, score, is_win, created_by, created_at)
      values(
        'R' || lpad(v_maxrec::text, 5, '0'), v_sid,
        coalesce(v_date, v_olddate), v_gid, v_dur,
        nullif(v_part->>'player_id',''),
        coalesce(v_part->>'player_name',''),
        nullif(v_part->>'score','')::numeric,
        coalesce((v_part->>'is_win')::boolean, false),
        v_created, v_now      -- 작성자는 원본 유지(관리자 수정에도 보존)
      );
    end loop;

    select count(*) into v_cnt from public.playlogs where session_id = v_sid;
    return json_build_object('session_id', v_sid, 'updated', v_cnt, 'mode', 'replace');
  end if;

  -- 레거시: 날짜·시간 + 참가자별 점수/승패만
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
