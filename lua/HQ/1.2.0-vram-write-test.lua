-- ★ HQ 1.2.0 -- **개입 실험**: VRAM 에 쓰기만 해도 국장실이 깨지는가
--
-- ⚠ 읽기 전용이 아니다.  일부러 VRAM 을 건드린다.
--
-- 앞선 결과
-- --------
-- `1.1.0` (0.5.10 + 슬롯 671 B 를 트랙 3 내내 점유):  ★멀쩡했다.
--   -> CPU 슬롯 점유도, 트랙 끝 복원도 **무죄**.
--   -> 저녁 내내 붙들었던 "게임의 스크립트 VM 스택을 뺏어서 막힌다" 는 기각.
--
-- 그러면 남은 것은 VRAM 쪽 둘이다:
--     ① 우리가 글리프를 쓰는 것            <- 이 판이 잰다
--     ② 헬퍼가 저장/복원하는 것            <- 다음 판
--
-- 이 판이 하는 일
-- --------------
-- **0.5.10** (트랙 3 자막 없음) 에서, 트랙 3 이 도는 동안 VRAM 의 글리프 블록
-- 자리를 **주기적으로 덮어쓴다.**  자막 시스템은 전혀 안 쓴다.
--
--     자리   BASE (word) 부터 1,216 word = 2,432 B      <- 0.5.18 이 쓰던 $4B00
--     주기   PERIOD 프레임마다 한 번 (자막 한 줄이 갱신되는 리듬을 흉내)
--
-- 왜 "주기적" 인가 -- 한 번만 쓰면 게임이 나중에 그 위에 덮어써서 아무 일도 안
-- 난다.  실제 자막은 트랙 내내 계속 쓴다.  0.5.17(58초까지 씀)과 0.5.18(33.8초
-- 까지 씀)의 차이가 바로 **전환 뒤에도 계속 쓰는가** 였다.
--
-- 판정
--     국장실에서 깨진다  -> ★그 자리에 쓰는 것만으로 충분.  원인 확정
--     멀쩡하다           -> 쓰기는 무죄.  헬퍼의 저장/복원(②) 이 원인
--
-- 바꿔 볼 것
--     BASE      다른 자리도 같은지 ($6300 · $7B00 ...)
--     STOP_SEC  33.8 로 두면 0.5.18 을 흉내낸다 (여기서 멈추면 멀쩡해야 한다)
--
-- 쓰는 법
--     ★ build/patch/0.5.10 으로 Power Cycle -> 이 파일 하나만
--     트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_1_2_0_vramwrite_<시각>.tsv

local VERSION = '1.2.0'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local BASE     = 0x4B00      -- word.  0.5.18 이 쓰던 자리
local WORDS    = 19 * 0x40   -- 1,216 word = 자막 한 조각
local PERIOD   = 120         -- 프레임.  2 초마다 한 번 덮어쓴다
local STOP_SEC = nil         -- 숫자를 넣으면 그 초까지만 쓴다 (0.5.18 흉내: 33.8)
local FILL     = 0x5A        -- 알아보기 쉬운 값

local CD_RAW = 0x26F9

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_vramwrite_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tcd_raw\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local startFrame = nil
local writes = 0

local function line(ev)
  local s = emu.getState() or {}
  local el = startFrame and string.format('%.2f', (frame - startFrame) / 60) or '-'
  out:write(string.format('%d\t%s\t%s\t%02X\t%04X\n',
    frame, el, ev, rb(CD_RAW), s['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end

local function paint()
  local at = BASE * 2
  for i = 0, WORDS * 2 - 1 do
    emu.write(at + i, FILL, VRAM)
  end
  writes = writes + 1
end

emu.addEventCallback(function()
  frame = frame + 1
  local t = rb(CD_RAW) & 0x7F
  if t ~= 3 then
    if startFrame then line('TRACK_END'); startFrame = nil end
    return
  end
  if startFrame == nil then
    startFrame = frame
    line('TRACK3_START')
    emu.log(string.format('★ 트랙 3 시작 frame=%d · $%04X 부터 %d word 를 %d 프레임마다 덮는다',
      frame, BASE, WORDS, PERIOD))
  end
  local el = (frame - startFrame) / 60
  if STOP_SEC and el > STOP_SEC then return end
  if (frame - startFrame) % PERIOD == 0 then
    paint()
    if writes <= 8 or writes % 5 == 0 then line('PAINT#' .. writes) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d paints=%d base=%04X words=%d\n',
    rows, frame, writes, BASE, WORDS))
  out:close()
  emu.log(string.format('★ 총 %d 회 덮어씀 -> %s', writes, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- ★개입 실험.  VRAM 글리프 자리에 쓰기만 한다')
emu.log('  ⚠ build/patch/0.5.10 으로 돌릴 것')
emu.log(string.format('  자리 $%04X · %d word · %d 프레임마다', BASE, WORDS, PERIOD))
emu.log('  깨지면 -> 그 자리에 쓰는 것이 원인.  멀쩡하면 -> 헬퍼 저장/복원 쪽')
emu.log('  -> ' .. OUT)
