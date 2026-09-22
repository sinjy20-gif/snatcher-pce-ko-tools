-- 사전 줄이 **어느 state 로 조회되는지** 잰다.  0.1.0
--
-- ★ 순수 관측.  아무것도 안 쓰고 화면에도 안 그린다
--   (RUNTIME_TEXT_AUDIT_0.2.3_MISSONLY 는 drawString 을 안 쓴다 -- 확인함).
--
-- 왜
-- --
-- 사전에서 페이지 첫 줄이 일본어로 남는다.  빌더는 페이지 경계를
-- `(line_no - 1) // 3` 으로 세는데 3 은 **대사 창** 높이라, 게임이 뿌리에서
-- 묻는 줄을 사슬에 등록해 버리는 자리가 생긴다.
--
-- 지금까지는 그것을 **화면을 보고** 갈랐다.  가우디 단말까지 걸어가서 눈으로
-- 확인하고, 안 되면 또 구워서 또 걸어갔다 (0.5.8 -> 0.5.9).  그 왕복이 비싸다.
--
-- 이 프로브는 그 자리에서 게임이 **실제로 무엇을 묻는지** 숫자로 남긴다.
--
--     state_before   게임이 조회를 시작한 state    ★이게 답이다
--     match_state    hit / miss
--     changed        치환이 실제로 일어났나
--     source_hex     원문 바이트
--     pack           $76 이면 가우디 사전
--
-- 한 번만 돌리면 다음부터는 굽기 전에 정적으로 판단할 수 있다.
--
-- ⚠ 세이브스테이트로 들어가면 안 된다
-- --------------------------------
-- 번역 페이로드는 부팅 때 AC $000000 으로 한 번 올라가고, 그 뒤 조회는 AC 에서만
-- 한다.  옛 빌드에서 뜬 스테이트를 불러오면 **디스크가 새것이어도 AC 에는 옛
-- 번역이 앉아 있다.**  반드시 부팅부터 돌릴 것.
--
-- 쓰는 법
-- -------
--   1) Mesen 에서 0.5.9 를 **부팅부터** 띄운다
--   2) 이 파일을 Script 로 연다
--   3) 가우디 단말 -> 사전 -> 문제되는 항목까지 넘긴다
--   4) ★ Stop 을 눌러야 마지막 레코드가 파일에 남는다
--
-- 산출물  C:/snatcher/snatcher_tool/logs/dict_lookup_state_v010.tsv
--
-- 읽는 법 (분석은 tools/report_dict_lookup_state.py 가 한다)
--   state_before=0000 인데 miss   -> 뿌리에 그 원문이 없다.  등록 자리가 틀렸다
--   state_before!=0000 인데 miss  -> 게임이 사슬로 묻는다.  뿌리로 올리면 안 된다
--   hit 인데 changed=no           -> 찾긴 했는데 렌더러가 안 바꿨다.  다른 문제다

SNATCHER_TEXT_ONLY = true
-- ★ 0.1.1 수집기와 다른 점: 미스만이 아니라 **전부** 남긴다.  hit 줄의
--   state_before 를 알아야 "게임이 여기서 뿌리로 묻는가" 를 가를 수 있다.
SNATCHER_VISIBLE_MISS_ONLY = false
SNATCHER_WHOLE_RECORD = false
SNATCHER_TEXT_OUTPUT = "C:/snatcher/snatcher_tool/logs/dict_lookup_state_v010.tsv"

dofile("C:/snatcher/lua/RUNTIME_TEXT_AUDIT_0.2.3_MISSONLY.lua")
