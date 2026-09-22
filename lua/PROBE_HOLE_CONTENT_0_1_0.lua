-- PROBE_HOLE_CONTENT 0.1.0  --  훅이 도는 그 순간 $7FA0 에 무엇이 들어 있나
--
-- 왜 이것만 따로 보나
-- -------------------
-- `PROBE_OVERLAY_HOLE 0.2.0` 이 26739 오버레이A 프레임 동안 $7FA0-$7FEB 에
-- 읽기·쓰기·실행이 0 건임을 보였다.  디스크에서도 그 자리는 FF 이고 정적 참조도
-- 0 군데다.  세 신호가 다 "빈 자리" 를 가리킨다.
--
-- 그런데 하나가 안 걸러졌다.  그 자리는 **헬퍼 케이브 주소 범위 $7CD2-$7FFF 안**이다.
--
--     PROBE_OVERLAY_TAIL 0.1.0:  write $EA9E 가 정확히 814 B  ($7CD2-$7FFF 크기)
--
-- 그 쓰기가 **오버레이 A 가 뜨기 전에** 일어나면 0.2.0 은 그것을 못 센다
-- (지문이 안 맞는 프레임은 세지 않으니까).  그러면 우리가 디스크에 박은 32 B 는
-- 실행되기 전에 덮인다.  훅은 멀쩡히 `JSR $7FA0` 하고, 그 자리엔 헬퍼가 있다.
--
--     디스크에 FF 인 것은 빈 공간이어서가 아니다  (헬퍼 케이브에서 한 번 데였다)
--
-- 그래서 **쓰기를 보는 대신 내용을 본다.**  값이 계속 FF 면 디스크 바이트가
-- 그대로 서 있는 것이고, 코드처럼 생긴 것이 들어오면 덮인 것이다.
--
-- 무엇을 재나
--   오버레이 A 가 살아 있는 프레임마다 $7FA0-$7FEB 76 B 를 읽어
--     · 전부 FF 인가
--     · 아니면 무엇으로 바뀌었나 (처음 바뀐 순간의 앞 16 B 를 찍는다)
--   덤으로 $7F88-$7F9F (0.2.0 이 "쓰인다" 고 한 바로 옆)도 같이 본다 --
--   거기가 무엇인지 알면 우리 자리의 성격도 같이 드러난다.
--
-- 아무것도 안 쓴다.  **평소처럼 진행하면 된다.**  장면을 몇 번 갈아타면 충분하다.
-- 출력  로그 + C:/snatcher/dump/probe_hole_content_0_1_0_<날짜>.tsv

local MEM = emu.memType.pceMemory
local LO, HI = 0x7FA0, 0x7FEB          -- 생존자
local NEIGH_LO, NEIGH_HI = 0x7F88, 0x7F9F   -- 옆칸 (쓰인다고 나온 곳)

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local frames, liveA = 0, 0
local all_ff_frames, dirty_frames = 0, 0
local first_dirty = -1
local lines = {}
local seen = {}                        -- 서로 다른 내용 지문 -> 처음 본 프레임
local kinds = 0                        -- 그 가짓수

local function say(s) emu.log(s); lines[#lines+1] = s end

local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if (emu.read(s[1] + i - 1, MEM) or 0) ~= s[2][i] then return false end
    end
  end
  return true
end

local function grab(lo, hi)
  local out = {}
  for a = lo, hi do out[#out+1] = emu.read(a, MEM) or 0 end
  return out
end

local function hex(t, n)
  local parts = {}
  for i = 1, math.min(n or #t, #t) do parts[#parts+1] = string.format('%02X', t[i]) end
  return table.concat(parts, ' ')
end

local function all_ff(t)
  for i = 1, #t do if t[i] ~= 0xFF then return false end end
  return true
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_hole_content_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  if not overlayA() then return end
  liveA = liveA + 1

  local body = grab(LO, HI)
  if all_ff(body) then
    all_ff_frames = all_ff_frames + 1
  else
    dirty_frames = dirty_frames + 1
    local key = hex(body, 16)
    if not seen[key] then
      seen[key] = liveA
      kinds = kinds + 1
      if first_dirty < 0 then
        first_dirty = liveA
        say(string.format('[오버레이A %d] ★ $7FA0 이 FF 가 아니다', liveA))
        say('    -> 디스크 바이트가 그대로 서 있지 않다.  여기 구우면 덮인다')
      end
      say(string.format('    내용 %d 번째: %s', kinds, key))
    end
  end

  if liveA % 600 == 0 then
    local neigh = grab(NEIGH_LO, NEIGH_HI)
    say(string.format('--- 오버레이A %d --- $7FA0 FF %d 프레임 · FF 아님 %d 프레임 · 서로 다른 내용 %d 가지',
          liveA, all_ff_frames, dirty_frames, kinds))
    say(string.format('    $7FA0  %s', hex(body, 16)))
    say(string.format('    $7F88  %s   (옆칸 -- 0.2.0 이 쓰인다고 한 곳)', hex(neigh, 16)))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_HOLE_CONTENT 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  묻는 것 하나: 훅이 도는 그 순간 $7FA0-$7FEB 에 디스크 바이트(FF)가 서 있나')
emu.log('  계속 FF 면 거기 구워도 된다.  바뀌면 런타임이 덮는 자리다')
emu.log('  평소처럼 진행하면 된다 -- 장면을 몇 번 갈아탈 것')
