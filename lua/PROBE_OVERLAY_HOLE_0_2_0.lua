-- PROBE_OVERLAY_HOLE 0.2.0  --  살아남은 구멍 하나를 험한 장면까지 끌고 가 본다
--
-- 0.1.0 에서 무엇이 바뀌었나
-- --------------------------
-- 0.1.0 은 73200 프레임 동안 읽기·쓰기·실행이 없던 구간 여섯을 뽑았다.  측정은
-- 옳게 만들어졌다 (셋 다 본다).  그런데 **디스크를 안 봤다.**
--
-- `tools/check_overlay_holes.py` 가 그 여섯을 디스크에서 확인했더니:
--
--     $6A94-$6B93  256 B   멀쩡한 루틴.  9 군데가 JSR/JMP 로 가리킨다
--     $78E5-$7998  180 B   루틴.  2 군데
--     $79C6-$7A5E  153 B   루틴.  4 군데
--     $7A8D-$7B00  116 B   루틴.  13 군데
--     $7C6F-$7CB3   69 B   루틴.  2 군데
--     $7FA0-$7FEB   76 B   전부 FF · 가리키는 곳 0 군데   <- 유일한 생존자
--
-- 다섯은 **휴면 코드**였다.  73200 프레임에서 안 돌았을 뿐 특정 장면의 경로다.
-- 덮었으면 그 장면에서 죽었을 것이다.
--
--     규칙 (ARENA §7): 안 건드리는 것을 못 봤다 != 죽은 자리
--     여기서는 그 역: **안 돌더라도 코드가 있으면 산 자리다**
--
-- 그래서 이 판은 하나만 본다.  대신 **더 험한 데까지** 끌고 간다.
--
-- 무엇을 재나
--   1  $7FA0-$7FEB 76 B 를 바이트 단위로.  읽기·쓰기·실행 전부
--   2  같은 김에 $6000-$7FFF 전체 구멍 지도를 다시 낸다 (0.1.0 목록이 줄었는지)
--   3  장면이 바뀔 때마다 그 시점의 구멍 크기를 찍는다 -- 어느 장면이 깎는지 보이게
--
-- 오버레이 A 지문이 맞는 프레임만 센다.  다른 오버레이가 그 자리를 쓰는 것은
-- 우리와 무관하다.
--
-- ★ 반드시 지나갈 것
--     접수처 대화 · 이동 · 메뉴 · 세이브/로드 · **사격 씬** · 장면 전환
--   0.1.0 의 목록은 "한 장면에 오래 머문" 탓에 부풀었을 수 있다.
--
-- 아무것도 안 쓴다.
-- 출력  로그 + C:/snatcher/dump/probe_overlay_hole_0_2_0_<날짜>.tsv (600 프레임마다)

local MEM = emu.memType.pceMemory
local LO, HI = 0x6000, 0x7FFF
local WATCH_LO, WATCH_HI = 0x7FA0, 0x7FEB      -- 유일한 생존자
local NEED = 32                                 -- 이보다 긴 구멍만 낸다

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local touched = {}          -- addr -> 처음 건드린 프레임
local how = {}              -- addr -> "r" / "w" / "x"
local frames, liveA = 0, 0
local watch_hits = 0
local lines = {}
local last_holes = -1

local function say(s) emu.log(s); lines[#lines+1] = s end

local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if (emu.read(s[1] + i - 1, MEM) or 0) ~= s[2][i] then return false end
    end
  end
  return true
end

local inA = false

local function mark(address, kind)
  if not inA then return end
  if address < LO or address > HI then return end
  if not touched[address] then
    touched[address] = frames
    how[address] = kind
    if address >= WATCH_LO and address <= WATCH_HI then
      watch_hits = watch_hits + 1
      say(string.format('[프레임 %d] ★★ 생존자가 깨졌다  $%04X  %s  (%d 번째)',
                        frames, address, kind, watch_hits))
      say('    -> $7FA0-$7FEB 도 빈 자리가 아니다.  감시자 자리를 다시 찾아야 한다')
    end
  end
end

emu.addMemoryCallback(function(a) mark(a, 'r') end, emu.callbackType.read, LO, HI)
emu.addMemoryCallback(function(a) mark(a, 'w') end, emu.callbackType.write, LO, HI)
emu.addMemoryCallback(function(a) mark(a, 'x') end, emu.callbackType.exec, LO, HI)

-- 이어진 무접촉 구간을 길이순으로
local function holes()
  local out, start = {}, nil
  for a = LO, HI do
    if touched[a] then
      if start and a - start >= NEED then out[#out+1] = { start, a - 1, a - start } end
      start = nil
    elseif not start then
      start = a
    end
  end
  if start and HI + 1 - start >= NEED then out[#out+1] = { start, HI, HI + 1 - start } end
  table.sort(out, function(p, q) return p[3] > q[3] end)
  return out
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_overlay_hole_0_2_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:write('\n구멍 지도\nfrom\tto\tbytes\n')
  for _, h in ipairs(holes()) do
    f:write(string.format('%04X\t%04X\t%d\n', h[1], h[2], h[3]))
  end
  f:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  inA = overlayA()
  if inA then liveA = liveA + 1 end

  if frames % 600 == 0 then
    local list = holes()
    local total = 0
    for _, h in ipairs(list) do total = total + h[3] end
    -- 구멍이 줄어든 순간만 짚는다 -- 어느 장면이 깎는지 보이게
    if last_holes < 0 or total < last_holes then
      say(string.format('--- %d --- 오버레이A %d 프레임 · 구멍 %d 곳 %d B%s',
            frames, liveA, #list, total,
            last_holes < 0 and '' or string.format('  (%d B 줄었다)', last_holes - total)))
      for i = 1, math.min(4, #list) do
        say(string.format('      $%04X-$%04X  %d B', list[i][1], list[i][2], list[i][3]))
      end
      say(string.format('      생존자 $7FA0-$7FEB : %s',
            watch_hits == 0 and '아직 깨끗하다' or string.format('★ 깨졌다 (%d)', watch_hits)))
      last_holes = total
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_OVERLAY_HOLE 0.2.0 loaded  --  아무것도 안 쓴다')
emu.log('  0.1.0 의 구멍 여섯 중 다섯은 휴면 코드였다 (디스크 확인)')
emu.log('  남은 후보 $7FA0-$7FEB 76 B 하나를 험한 장면까지 끌고 간다')
emu.log('  ★ 세이브/로드 · 사격 씬 · 장면 전환을 반드시 지나갈 것')
