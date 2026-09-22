-- Missing/untranslated dialogue -- whole-record preservation.  0.1.0 다음이다.
--
-- 0.1.0 은 미스 줄만 기록했다.  그런데 한 레코드 안에서 일부 줄만 미스인
-- **부분 치환**이 있다.  미스만 남기면 나중에 이 로그를 마스터에 편입할 때
-- hit 줄이 빠진 채로 레코드가 복원된다 -- 61 레코드 중 5 개에서 확인됐다.
--
-- 0.1.1 은 레코드 단위로 모아 두고, 미스가 하나라도 있으면 **hit 줄까지 전부**
-- 남긴다.  미스가 없는 레코드는 통째로 버린다 (0.1.0 과 같다).
--
--     match_state 열이 맨 뒤에 붙는다.  hit / miss
--     ★ Stop 을 눌러야 마지막 레코드가 파일에 남는다
--
-- 출력이 0.1.0 과 **다른 파일**이다.  열이 하나 늘었으므로 섞으면 안 되고,
-- 0.1.0 수집분 61 레코드는 그대로 살려 둔다 (56 개는 온전하다).
SNATCHER_TEXT_ONLY = true
SNATCHER_VISIBLE_MISS_ONLY = true
SNATCHER_WHOLE_RECORD = true
SNATCHER_TEXT_OUTPUT = "C:/snatcher/snatcher_tool/logs/runtime_missing_text_raw_v011.tsv"
dofile("C:/snatcher/lua/RUNTIME_TEXT_AUDIT_0.2.3_MISSONLY.lua")
