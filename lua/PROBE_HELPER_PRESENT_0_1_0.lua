-- PROBE_HELPER_PRESENT 0.1.0  --  $7CD2 에 헬퍼 이미지가 앉아 있나
--
-- 무엇을 가르려는가
-- -----------------
-- `$7FA0` 에 구운 표식 32 B 가 런타임에 한 번도 안 나타났다 (10200 프레임 · 전부 FF).
-- 해석이 둘이다:
--
--     A  런타임이 그 범위를 덮는다           -> 디스크에 구우면 지워진다
--     B  패치 디스크로 안 켰다                -> 실험이 성립을 안 했다
--
-- 프로브는 어느 디스크로 켰는지 알 수 없다.  그래서 **다른 것을 본다.**
--
-- `$7CD2-$7F48` 631 B 는 디스크에서 전부 FF 다 (헬퍼 코드 크기와 같다).
-- 런타임에 거기 **코드가 들어 있으면** 그 범위는 통째로 덮이는 것이고,
-- 그러면 $7FA0 이 FF 인 이유도 설명된다 -- 헬퍼의 안 쓰는 꼬리가 FF 이기 때문이다.
-- 이 판정은 어느 디스크로 켰든 똑같이 성립한다.
--
--     디스크   $7CD2-$7FFF  814 B 전부 FF
--     매니페스트  helper_code_bytes 631 · helper_image_bytes 799 · helper_free_bytes 151
--     $7CD2 + 631 = $7F49   <- 여기부터가 여유
--     $7F49 + 151 = $7FE0   <- 0.1.1 이 더러워진다고 한 바로 그 지점
--
-- 무엇을 재나
--   오버레이 A 가 사는 프레임마다 다섯 창을 읽어 FF 인지 아닌지 본다.
--     $7CD2  헬퍼 머리      코드면 -> 덮인다
--     $7E00  헬퍼 중간
--     $7F40  헬퍼 코드 끝머리
--     $7F49  여유 시작
--     $7FA0  우리가 노린 자리
--   앞 12 B 를 그대로 찍는다.  눈으로 코드인지 알아볼 수 있게.
--
-- 아무것도 안 쓴다.  **아무 디스크로나 켜도 된다** (원본이어도 답이 나온다).
-- 출력  로그 + C:/snatcher/dump/probe_helper_present_0_1_0_<날짜>.tsv

local MEM = emu.memType.pceMemory
local SETTLE = 30
local SPOTS = {
  { 0x7CD2, '헬퍼 머리 (디스크 FF)' },
  { 0x7E00, '헬퍼 중간 (디스크 FF)' },
  { 0x7F40, '헬퍼 코드 끝머리' },
  { 0x7F49, '여유 시작 = $7CD2+631' },
  { 0x7FA0, '우리가 노린 자리' },
}

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local streak, liveA = 0, 0
local nonff = {}                       -- 창 -> 한 번이라도 FF 가 아니었나
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

local function window(at, n)
  local parts, allff = {}, true
  for i = 0, n - 1 do
    local v = emu.read(at + i, MEM) or 0
    if v ~= 0xFF then allff = false end
    parts[#parts+1] = string.format('%02X', v)
  end
  return table.concat(parts, ' '), allff
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_helper_present_0_1_0_%s.tsv',
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

  if liveA == 1 or liveA % 600 == 0 then
    say(string.format('--- 오버레이A %d ---', liveA))
    for _, spot in ipairs(SPOTS) do
      local text, allff = window(spot[1], 12)
      if not allff then nonff[spot[1]] = true end
      say(string.format('  $%04X  %s   %s%s', spot[1], text, spot[2],
                        allff and '   [전부 FF]' or '   ★ FF 아님'))
    end
    local head = nonff[0x7CD2] or nonff[0x7E00] or nonff[0x7F40]
    if head then
      say('  -> 헬퍼 코드 범위에 무언가 들어 있다.  $7CD2-$7FFF 는 런타임이 채운다')
      say('     그러면 디스크에 구운 것은 지워진다.  헬퍼 이미지 쪽에 넣어야 한다')
    else
      say('  -> 헬퍼 코드 범위도 전부 FF 다.  이 장면에서는 헬퍼가 안 올라온 것이다')
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_HELPER_PRESENT 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  $7CD2-$7F48 은 디스크에서 전부 FF 다.  런타임에 코드가 있으면 덮이는 자리다')
emu.log('  ★ 아무 디스크로나 켜도 된다 -- 원본이어도 답이 나온다')
