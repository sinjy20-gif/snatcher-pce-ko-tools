-- SUB 0.4.41 -- 0.4.38 + stage 재무장.  다중 조각 정지의 실제 원인을 막는다.
--
-- ── 무엇이 문제였나 (0.4.40-callflow 측정 + 엔진 소스로 확정) ───────────────
--
-- 엔진 진입부는 이렇게 생겼다 (engine_ac_lua_frame_mini.bin 실측 바이트):
--
--     +3   AD D7 5C   LDA $5CD7      ; ready
--     +6   D0 06      BNE +6         ; ready != 0 -> +14 (JMP push)
--     +8   20 77 5D   JSR $5D77      ; ready == 0 -> stage 를 코드로 호출
--     +11  4C 91 5B   JMP $5B91      ; rebuild
--
-- $5D77 = stage (engine off 503) 에는 31 B 팔레트 초기화 루틴이 깔려 있고
-- $5D95 의 RTS 로 끝난다.  그런데 **같은 stage 가 글리프 전송 버퍼다**:
--
--     TIA AC_PORT -> stage        (build_subtitle_engine_ac_record_poc.py)
--     TIA stage   -> VDC_VWR
--
-- 즉 첫 rebuild 가 그 루틴을 글리프 비트맵으로 덮어쓴다.  빌더 주석이 전제를
-- 그대로 적어 놨다 -- "자체 전환은 entry 가 아니라 rebuild 로 직접 가므로 두 번
-- 부르지 않는다".  엔진 스스로는 JSR stage 를 딱 한 번만 지난다.
--
-- 그런데 0.4.31 의 Lua 프레임 타이머는 조각 전환마다 ready=0 을 쓴다.
-- 그래서 전환이 매번 entry 를 거치고, 매번 **글리프 픽셀을 코드로 JSR** 한다.
--
--     조각 1  stage = 진짜 팔레트 루틴      -> RTS 로 복귀 · rebuild ✓
--     조각 2  stage = 조각1 의 글리프 비트맵 -> 우연히 복귀 · rebuild ✓
--     조각 3  stage = 조각2 의 글리프 비트맵 -> 복귀 실패 · 폭주 ✗
--
-- 0.4.40-callflow 측정이 이것과 정확히 맞는다:
--   정지 프레임에도 HOOK=1 ENTRY=1 이 왔고 (호출 경로는 멀쩡했다)
--   REBUILD=0 COUNTOK=0 이었으며 (JSR 이 돌아오지 못해 +11 에 못 갔다)
--   정지 후 endFrame PC 표본이 $5D97~$5DA1 -- 사라진 RTS 바로 다음이었다.
--
-- ── 고치는 법 ──────────────────────────────────────────────────────────────
--
-- entry 를 지날 때 ready==0 이면, JSR 이 일어나기 전에 stage 의 31 B 를 원본
-- 이미지에서 되살린다.  그러면 JSR stage 는 언제나 유효한 코드를 부르고 RTS 로
-- 돌아와 rebuild 로 간다.  엔진 재빌드도 디스크 빌드도 없다.
--
-- 팔레트 루틴을 다시 도는 것은 무해하다 (VCE 주소 $01F1 에 색 두 개를 쓸 뿐이다).
-- 오히려 음성 사이에 게임이 팔레트를 건드렸다면 되돌려 주는 쪽이 안전하다.
--
-- 안전장치: $5B80 에 우리 엔진이 없을 때 (음성 사이에는 게임 코드가 있다)
-- 절대 쓰지 않는다.  매직 "SUB" 와 JSR 피연산자를 둘 다 확인한 뒤에만 쓴다.

dofile('C:/snatcher/lua/SUB/0.4.38.lua')

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE = 0x5B80
local ENTRY  = ENGINE + 3
local READY  = ENGINE + 343
local STAGE  = ENGINE + 503          -- $5D77

local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_mini.bin'
local f = assert(io.open(ENGINE_PATH, 'rb'), 'cannot open ' .. ENGINE_PATH)
local image = f:read('*a'); f:close()
assert(#image == 631, 'unexpected engine size: ' .. #image)

-- 원본 stage 앞부분에서 RTS($60)까지가 팔레트 루틴이다.  길이를 상수로 박지
-- 않고 이미지에서 재어 온다 -- 엔진이 바뀌어도 따라간다.
local ROUTINE
do
  local at = image:find('\x60', 504, true)          -- 1-based: stage = 504
  assert(at and at - 504 < 64, 'stage 안에서 RTS 를 못 찾았다')
  ROUTINE = image:sub(504, at)
end

-- 실행 시점에 확인할 지문.  이게 안 맞으면 우리 엔진이 아니다.
local MAGIC = image:sub(1, 3)                        -- "SUB"
local JSR   = image:sub(9, 11)                       -- 20 77 5D

local function matches(at, want)
  for i = 1, #want do
    if (emu.read(at + i - 1, MEM) or -1) ~= want:byte(i) then return false end
  end
  return true
end

local rearmed, skipped = 0, 0

emu.addMemoryCallback(function()
  if (emu.read(READY, MEM) or 0xFF) ~= 0 then return end   -- rebuild 요청일 때만
  if not matches(ENGINE, MAGIC) or not matches(ENGINE + 8, JSR) then
    skipped = skipped + 1
    return
  end
  if matches(STAGE, ROUTINE) then return end               -- 이미 멀쩡하다
  for i = 1, #ROUTINE do
    emu.write(STAGE + i - 1, ROUTINE:byte(i), MEM)
  end
  rearmed = rearmed + 1
  emu.log(string.format('SUB 0.4.41 ★ stage 재무장 #%d · $%04X %d B (JSR 직전)',
                        rearmed, STAGE, #ROUTINE))
end, emu.callbackType.exec, ENTRY, ENTRY, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 34, string.format('0.4.41 stage rearm %d%s', rearmed,
                 skipped > 0 and ('  skip ' .. skipped) or ''),
                 0xFFD060, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.41 armed -- entry 에서 ready==0 이면 JSR 전에 stage 31 B 를 되살린다')
emu.log(string.format('  stage $%04X · 루틴 %d B (RTS 포함) · 매직/JSR 지문 확인 후에만 쓴다',
                      STAGE, #ROUTINE))
emu.log('  기대: 미카 3조각이 모두 뜨고 전환마다 REBUILD/COUNTOK 가 1회씩 온다')
