-- PROBE_MARKER_ALIVE 0.1.0  --  디스크에 구운 32 B 가 런타임까지 살아남나
--
-- 무엇을 가르나
-- -------------
-- `$7FA0-$7FDF` 는 디스크에서도 FF 이고 런타임에서도 FF 다.  그래서 두 가설이
-- 화면상 똑같이 보인다:
--
--     A  디스크 바이트가 그대로 서 있다          -> 여기 상주부를 구우면 된다
--     B  로더가 814 B 를 채우며 FF 로 덮는다      -> 구워도 지워진다
--
-- `tools/bake_hole_marker.py` 가 `$7FA0` 에 `40 41 42 ... 5F` 를 구웠다.
-- 그 32 B 를 읽어 보면 갈린다.  **`$601E` 는 안 건드렸으므로 실행되는 것은 없다.**
--
--     ★ 반드시 build/patch/hole_marker/ 의 디스크로 켤 것
--       원본으로 켜면 당연히 FF 만 나온다 (그건 B 의 증거가 아니다)
--
-- 무엇을 재나
--   오버레이 A 가 사는 프레임마다 `$7FA0-$7FDF` 32 B 를 읽어
--     · 표식과 몇 바이트가 맞나
--     · 안 맞는 바이트는 무엇으로 바뀌었나
--   표식이 처음 나타난 프레임과, 한 번이라도 깨진 프레임을 짚는다.
--
-- 아무것도 안 쓴다.  평소처럼 진행하면 된다 -- 장면을 몇 번 갈아탈 것.
-- 출력  로그 + C:/snatcher/dump/probe_marker_alive_0_1_0_<날짜>.tsv

local MEM = emu.memType.pceMemory
local AT, SIZE = 0x7FA0, 32
local SETTLE = 30

local MARK = {}
for i = 0, SIZE - 1 do MARK[i] = 0x40 + i end

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local streak, liveA = 0, 0
local first_full, first_broken = -1, -1
local full_frames, ff_frames, other_frames = 0, 0, 0
local worst = SIZE                      -- 가장 적게 맞았던 횟수
local lines = {}

local function say(s) emu.log(s); lines[#lines+1] = s end

local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if (emu.read(s[1] + i - 1, MEM) or 0) ~= s[2][i] then return false end
    end
  end
  return true
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_marker_alive_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:close()
end

emu.addEventCallback(function()
  if not overlayA() then streak = 0; return end
  streak = streak + 1
  if streak < SETTLE then return end
  liveA = liveA + 1

  local hit, allff, shown = 0, true, {}
  for i = 0, SIZE - 1 do
    local v = emu.read(AT + i, MEM) or 0
    if v == MARK[i] then hit = hit + 1 end
    if v ~= 0xFF then allff = false end
    if i < 12 then shown[#shown+1] = string.format('%02X', v) end
  end
  if hit < worst then worst = hit end

  if hit == SIZE then
    full_frames = full_frames + 1
    if first_full < 0 then
      first_full = liveA
      say(string.format('[오버레이A %d] ★ 표식 32/32 -- 디스크 바이트가 살아 있다', liveA))
    end
  else
    if allff then ff_frames = ff_frames + 1 else other_frames = other_frames + 1 end
    if first_broken < 0 then
      first_broken = liveA
      say(string.format('[오버레이A %d] ★ 표식이 %d/32 만 맞는다  %s%s', liveA, hit,
                        table.concat(shown, ' '), allff and '   (전부 FF -- 덮였다)' or ''))
    end
  end

  if liveA % 600 == 0 or liveA == 1 then
    say(string.format('--- 오버레이A %d --- 온전 %d · 전부FF %d · 그밖 %d · 최저 일치 %d/32',
                      liveA, full_frames, ff_frames, other_frames, worst))
    say(string.format('    $7FA0  %s', table.concat(shown, ' ')))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_MARKER_ALIVE 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  ★ build/patch/hole_marker/ 의 디스크로 켰는지 확인할 것')
emu.log('  40 41 42 ... 5F 가 그대로면 -> 디스크 바이트가 산다')
emu.log('  전부 FF 면 -> 로더가 덮는다.  다른 자리를 찾아야 한다')
