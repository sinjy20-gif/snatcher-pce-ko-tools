-- SUB titlewipe-probe 0.1 -- §8-B 와이프 스텁의 판정식을 실측한다.  읽기 전용.
--
-- 왜 만들었나 (2026-08-31)
-- ----------------------
-- 세이브 -> 타이틀 -> 재로드 화면 깨짐(§8-B)이 0.4.6.22 에서 재발했다.  원인은
-- 이미 찾았다: 핸들러 테이블 $7331 이 `BD 73` 원본 그대로다.  즉 우회가 안 걸려
-- 스텁이 **한 번도 실행되지 않는다** (0.4.5.9 / 0.4.6.10 은 `EF 7C`).
--
-- 그런데 우회를 얹기 전에 먼저 확인할 것이 있다.  스텁은 조건부다:
--
--     ①  ($FA),Y  (Y=$0A) == $95     타이틀 spawn 서명
--     ②  $5B80             == $53     우리 stale 레코드가 실제로 있다
--
-- 둘 다 2026-08-15 에 0.3.6 기준으로 정한 값이다.  그 뒤 엔진이 BIOS 폰트 경로로
-- 통째로 바뀌었다.  서명이 그때 그대로라는 보장이 없다.  안 맞으면 우회를 얹어도
-- 스텁은 그냥 지나가고 깨짐은 그대로다 -- 고쳤다고 착각한 채로.
--
-- 그래서 우회 없이 먼저 잰다.  원래 핸들러 $73BD 는 우회와 무관하게 매번
-- 실행되므로, 거기서 같은 두 값을 읽으면 "우회를 얹었다면 스텁이 탔을까" 가
-- 그대로 나온다.
--
-- 무엇을 쓰지 않는가
-- -----------------
-- 아무것도 안 쓴다.  $1A00-$1A04 는 읽지도 않는다 -- Arcade Card 포트라 읽는
-- 것 자체가 상태를 움직인다.  스텁이 거기서 복원해 오는 것이 맞지만, 그것을
-- 확인하겠다고 포트를 건드리면 측정이 대상을 바꾼다.
--
-- 쓰는 법
-- ------
--   1  파워사이클
--   2  이 스크립트만 올린다 (수집기·자막 엔진과 같이 올리지 말 것)
--   3  플레이 -> 게임 내 저장 -> 타이틀 복귀 -> 같은 슬롯 재로드
--   4  깨짐이 보이면 Stop.  dump\titlewipe_probe_<시각>.tsv 를 본다
--
-- 읽는 법
-- ------
--   spawn 행마다 sig / rec 가 찍힌다.
--     sig=95 rec=53   두 판정식 다 성립 -> 우회만 얹으면 고쳐진다
--     sig=95 rec≠53   서명은 살아 있는데 레코드 마커가 바뀌었다 -> ② 를 고쳐야 한다
--     sig≠95 뿐       타이틀 서명이 죽었다 -> ① 부터 다시 잡아야 한다
--   `stub_ran` 열은 우회가 걸린 디스크에서만 1 이 된다 (0.4.6.22 는 항상 0).

local mem = emu.memType.pceMemory
local ZP  = 0x2000              -- HuC6280 제로페이지는 $2000-$20FF 로 보인다

local SPAWN_HANDLER = 0x73BD    -- 씬 VM opcode 2 원래 핸들러.  항상 실행된다
local STUB          = 0x7CEF    -- title_cache_wipe 진입.  우회가 걸려야만 실행
local STUB_WIPE     = 0x7D09    -- TAI $1A00 -> $5B80.  여기 오면 실제로 지운 것
local RECORD        = 0x5B80    -- 레코드 캐시 머리

local SIG_TITLE  = 0x95
local SIG_RECORD = 0x53

local stamp = os.date('%Y%m%d_%H%M%S')
local path  = 'C:/snatcher/dump/titlewipe_probe_' .. stamp .. '.tsv'
local out = assert(io.open(path, 'w'))
out:write('seq\tframe\twhere\ttask_ptr\tsig\trec\tcond1\tcond2\tstub_ran\twipe_ran\trec_head\n')
out:flush()

local frame, seq = 0, 0
local stubRan, wipeRan = 0, 0
local titleSpawns, bothTrue = 0, 0

local function byte(a) return emu.read(a, mem) or 0 end

-- $5B80 머리 16 B.  판정식 ② 가 안 맞을 때 "그럼 뭐가 들어 있나" 가 바로 나온다.
local function recordHead()
  local t = {}
  for i = 0, 15 do t[#t + 1] = string.format('%02X', byte(RECORD + i)) end
  return table.concat(t, ' ')
end

local function log(where)
  local ptr = byte(ZP + 0xFA) + byte(ZP + 0xFB) * 0x100
  local sig = byte(ptr + 0x0A)
  local rec = byte(RECORD)
  local c1  = sig == SIG_TITLE and 1 or 0
  local c2  = rec == SIG_RECORD and 1 or 0
  seq = seq + 1
  out:write(string.format('%d\t%d\t%s\t%04X\t%02X\t%02X\t%d\t%d\t%d\t%d\t%s\n',
    seq, frame, where, ptr, sig, rec, c1, c2, stubRan, wipeRan, recordHead()))
  out:flush()

  -- 타이틀 서명이 뜬 순간만 로그에 띄운다.  spawn 자체는 수천 번이라 다 띄우면
  -- 정작 봐야 할 줄이 묻힌다.
  if c1 == 1 then
    titleSpawns = titleSpawns + 1
    if c2 == 1 then bothTrue = bothTrue + 1 end
    emu.log(string.format(
      '★ TITLE spawn #%d  frame=%d  where=%s  ($FA)=%04X sig=%02X  $5B80=%02X  -> %s',
      titleSpawns, frame, where, ptr, sig, rec,
      c2 == 1 and '두 판정식 다 성립 (우회만 얹으면 탄다)'
              or string.format('②  실패 -- $5B80 이 %02X 다 (기대 %02X)', rec, SIG_RECORD)))
  end
end

emu.addMemoryCallback(function() log('handler') end,
  emu.callbackType.exec, SPAWN_HANDLER, SPAWN_HANDLER, emu.cpuType.pce, mem)

-- 우회가 걸린 디스크(0.4.5.9 / 0.4.6.10)에서만 불린다.  같은 스크립트로 두 판을
-- 비교할 수 있게 미리 걸어 둔다.
emu.addMemoryCallback(function()
  stubRan = stubRan + 1
  log('stub')
end, emu.callbackType.exec, STUB, STUB, emu.cpuType.pce, mem)

emu.addMemoryCallback(function()
  wipeRan = wipeRan + 1
  emu.log(string.format('★★ WIPE 실행 #%d  frame=%d  직전 $5B80=%s',
                        wipeRan, frame, recordHead()))
end, emu.callbackType.exec, STUB_WIPE, STUB_WIPE, emu.cpuType.pce, mem)

emu.addEventCallback(function()
  frame = frame + 1
  -- 매 프레임 그린다.  drawString 은 그 프레임에만 남으므로 띄엄띄엄 부르면
  -- 화면에서 깜빡일 뿐 계기판이 안 된다.
  emu.drawString(4, 4, string.format('TITLEWIPE  spawn %d  title %d  stub %d  wipe %d',
                                     seq, titleSpawns, stubRan, wipeRan), 0xFFFFFF, 0x000000, 180)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  emu.log(string.format('TITLEWIPE PROBE 끝 -- spawn %d · 타이틀 서명 %d · 두 판정식 %d · 스텁 %d · 실제 와이프 %d',
                        seq, titleSpawns, bothTrue, stubRan, wipeRan))
  if titleSpawns == 0 then
    emu.log('  ★ 타이틀 서명이 0 이다.  판정식 ① ($FA),Y==$95 가 이 빌드에서 죽었다는 뜻 --')
    emu.log('    우회를 얹어도 스텁은 안 탄다.  서명부터 다시 잡아야 한다')
  end
  emu.log('  -> ' .. path)
end, emu.eventType.scriptEnded)

emu.log('SUB titlewipe-probe 0.1 loaded -- §8-B 판정식 실측 · 읽기 전용 · 아무것도 안 쓴다')
emu.log('  재현: 플레이 -> 게임 내 저장 -> 타이틀 복귀 -> 같은 슬롯 재로드')
emu.log('  타이틀 서명이 뜰 때만 로그에 띄운다.  전수는 TSV 에 있다')
emu.log('  -> ' .. path)
