-- SUB 0.5.1 -- 이분 ④: 엔진을 자리에만 올리고 아무것도 안 시킨다.
--
-- 여기까지
-- ---------------------------------------------------------------------------
--     0.4.97  와이프 없음       -> 증상 남음     와이프 무죄
--     0.4.99  그리기 없음       -> 증상 사라짐   적재/RAM 쓰기 무죄
--     0.5.0   VCE 팔레트 없음   -> 증상 남음     A4 무죄
--
-- 남은 셋:
--
--     A1  $5B80 점유    엔진이 게임 스크립트 VM 데이터 스택에 복사되는 것 자체
--     A2  VRAM 전송     글리프 -> $1600
--     A3  SATB 푸시     JSR $6463 로 게임 스프라이트 푸시 루프 호출
--
-- 이 판
-- ---------------------------------------------------------------------------
-- 진입점(offset 3 · CPU $5B83)에 RTS 한 바이트를 박은 엔진을 쓴다.
-- gate 는 그대로 열리고 헬퍼가 653 B 를 $5B80 으로 **복사한다.**  엔진은
-- 들어오자마자 돌아간다.  즉 A1 만 남고 A2·A3·A4 는 전부 빠진다.
--
--     python tools/make_engine_entry_rts.py
--     -> engine_ac_lua_frame_rearm_entryrts.bin  (원본과 +3 한 바이트만 다르다)
--
-- 판정
--     번쩍임이 남으면   ★ A1 -- 엔진이 그 자리를 차지하는 것만으로 깨진다.
--                       $5B80 은 게임 스크립트 VM 데이터 스택이다.  "음성 중에만
--                       빌린다" 는 전제가 국장실에서는 안 통한다는 뜻이 된다
--     사라지면          A2 또는 A3.  다음은 그 둘을 가른다
--                       (푸시 0 개 엔진 / 전송 0 회 엔진)
--
-- ★ 자막은 안 나온다.  정상이다.
--   로그에서 STAGE REARM 은 찍히고 (entry 는 실행되므로) **PATCHED 는 안 찍혀야**
--   한다.  그게 "복사는 됐고 실행은 안 됐다" 의 증거다.  PATCHED 가 찍히면
--   이 실험은 성립하지 않은 것이니 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.

assert(rawget(_G, 'SUB_FRAGMENT_FORCE_KEY') == nil and
       rawget(_G, 'SUB_FRAGMENT_FORCE_BASE') == nil,
       '재무장 엔진에서는 SUB_FRAGMENT_FORCE_KEY/BASE 를 쓸 수 없다')

SUB_REARM_INFO_PATH =
  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_rearm_entryrts.lua'
dofile('C:/snatcher/lua/SUB/0.4.89-marker.lua')
SUB_REARM_INFO_PATH = nil

emu.log('SUB 0.5.1-no-execute armed -- 진입점 RTS · 복사만 되고 실행은 없다')
emu.log('  ★ 자막 없음이 정상 · STAGE REARM 은 찍히고 PATCHED 는 안 찍혀야 한다')
emu.log('  PATCHED 가 찍히면 실험 불성립이니 판정하지 말 것')
