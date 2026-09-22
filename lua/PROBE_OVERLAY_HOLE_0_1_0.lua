-- PROBE_OVERLAY_HOLE 0.1.0  --  오버레이 A 안에서 정말 안 쓰는 구멍을 찾는다
--
-- 왜
-- --
-- 디스크 패치의 스텁(54 B)을 놓을 자리가 필요하다.  스텁이 오버레이 A 안에 있으면
-- 훅과 스텁이 **같이 로드되고 같이 덮이므로** 잔류 문제가 원천적으로 사라진다.
--
-- 첫 후보 $7CD2-$7FFF 는 디스크에서 $FF 였고 정적 참조도 0 개였다.  그런데
-- PROBE_OVERLAY_TAIL 0.1.0 이 19200 프레임을 돌려 뒤집었다:
--
--     exec  오버레이 A 중 2752 회   $7D08 $7D0B $7D19 $7DE4 $7E1F $7F52 ...
--     write $EA9E 가 정확히 814 B   ← 우리가 본 범위 크기와 같다
--
-- 런타임에 $EA9E 의 루틴이 그 자리를 통째로 채운다.  **디스크의 FF 는 빈 공간이
-- 아니다.**  그리고 600 프레임 시점에는 "건드린 적 없다" 가 떴다 -- 짧게 재고
-- 끝냈으면 틀린 결론으로 디스크를 망가뜨렸을 것이다.
--
-- 이 판은 짚어보지 않고 **훑는다**.  $6000-$7FFF 전체에서 오버레이 A 가 살아 있는
-- 동안 한 번도 읽거나 쓰거나 실행하지 않은 구간을 찾아 길이순으로 낸다.
--
-- 무엇을 재나
--   바이트마다 touched 표를 채운다.  오버레이 A 지문이 맞는 프레임에만 센다 --
--   다른 오버레이가 그 자리를 쓰는 것은 우리와 무관하기 때문이다.
--
-- 아무것도 안 쓴다.  **오래 돌릴 것.**  대사 · 이동 · 메뉴 · 전투 · 장면 전환을
-- 두루 지나가야 한다.  짧게 돌리면 거짓 구멍이 나온다 (앞 판이 그랬다).
--
-- 출력  로그 + C:/snatcher/dump/probe_overlay_hole_0_1_0_<날짜>.tsv (600 프레임마다)

local MEM = emu.memType.pceMemory
local LO, HI = 0x6000, 0x7FFF
local NEED = 54                    -- 스텁 크기.  이보다 긴 구멍만 쓸모 있다

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local touched = {}                 -- addr -> true (오버레이 A 중에 건드린 것만)
local frames, liveA, other = 0, 0, 0
local nRead, nWrite, nExec = 0, 0, 0
local inA = false
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function rb(a) return emu.read(a, MEM) or 0 end
local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if rb(s[1] + i - 1) ~= s[2][i] then return false end
    end
  end
  return true
end

emu.addMemoryCallback(function(addr)
  if inA then touched[addr] = true; nRead = nRead + 1 end
end, emu.callbackType.read, LO, HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(addr)
  if inA then touched[addr] = true; nWrite = nWrite + 1 end
end, emu.callbackType.write, LO, HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(addr)
  if inA then touched[addr] = true; nExec = nExec + 1 end
end, emu.callbackType.exec, LO, HI, emu.cpuType.pce, MEM)

local function holes()
  local out, start = {}, nil
  for a = LO, HI do
    if touched[a] then
      if start then out[#out+1] = { start, a - start }; start = nil end
    else
      if not start then start = a end
    end
  end
  if start then out[#out+1] = { start, HI + 1 - start } end
  return out
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_overlay_hole_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, l in ipairs(lines) do f:write(l .. '\n') end
    f:close()
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  inA = overlayA()
  if inA then liveA = liveA + 1 else other = other + 1 end

  if frames % 600 == 0 then
    local list = holes()
    local big = {}
    for _, h in ipairs(list) do if h[2] >= NEED then big[#big+1] = h end end
    table.sort(big, function(a, b) return a[2] > b[2] end)
    local seen = 0
    for a in pairs(touched) do seen = seen + 1 end
    say(string.format('--- %d 프레임 --- 오버레이 A %d / 그 밖 %d · 건드린 바이트 %d/%d (%.1f%%)',
          frames, liveA, other, seen, HI - LO + 1, seen * 100.0 / (HI - LO + 1)))
    say(string.format('    read %d · write %d · exec %d · %d B 이상 구멍 %d 개',
          nRead, nWrite, nExec, NEED, #big))
    for i = 1, math.min(6, #big) do
      say(string.format('      $%04X - $%04X   %4d B', big[i][1], big[i][1] + big[i][2] - 1, big[i][2]))
    end
    if #big == 0 then say('      ★ 쓸 만한 구멍이 없다 -- 스텁을 오버레이 밖에 둬야 한다') end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_OVERLAY_HOLE 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log(string.format('  $%04X-$%04X 전체를 훑어 %d B 이상 안 쓰는 구간을 찾는다', LO, HI, NEED))
emu.log('  ★ 오래 돌릴 것.  짧게 돌리면 거짓 구멍이 나온다 (앞 판이 600 프레임에 그랬다)')
