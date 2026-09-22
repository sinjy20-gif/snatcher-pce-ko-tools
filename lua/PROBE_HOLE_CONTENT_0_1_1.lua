-- PROBE_HOLE_CONTENT 0.1.1  --  76 B 중 **어느 바이트**가 FF 가 아닌가
--
-- 0.1.0 이 왜 모자랐나
-- --------------------
-- 0.1.0 은 판정은 76 B 전체로 하면서 화면에는 앞 16 B 만 찍었다.  그래서 이런
-- 모순된 줄이 나왔다:
--
--     $7FA0 FF 0 프레임 · FF 아님 20400 프레임
--         $7FA0  FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF
--
-- "FF 가 아니다" 는 맞는데 **어디가** 아닌지를 안 보여줬다.  내용 지문도 앞
-- 16 B 로만 만들어서 "서로 다른 내용 2 가지" 도 못 믿는다.
--
-- 알아낸 것과 남은 것
-- -------------------
--     확정   $7FA0-$7FEB 76 B 가 런타임에 전부 FF 는 아니다
--     확정   오버레이 A 가 사는 동안 그 범위에 쓰기 0 건 (0.2.0)
--            -> 오버레이 A 가 뜨기 **전에** 채워진다
--     남은 것  76 B 중 몇 바이트가, 어디가 더러운가
--
-- 앞쪽이 깨끗하면 상주부 32 B 는 거기 들어간다.  그것만 보면 된다.
--
-- 무엇을 재나
--   바이트마다 "한 번이라도 FF 가 아니었나" 를 표로 쌓는다.
--     .  한 번도 FF 아닌 적이 없다      -> 쓸 수 있는 후보
--     X  한 번이라도 FF 가 아니었다      -> 못 쓴다
--   그리고 **연속으로 깨끗한 가장 긴 구간**을 낸다.  32 B 이상이면 답이 나온 것이다.
--
-- 지문은 76 B 전부로 만든다 (0.1.0 은 16 B 로 만들어 틀렸다).
--
-- 첫 프레임 함정
--   0.1.0 은 오버레이A 1 프레임째에 엉뚱한 값을 봤다.  로드가 끝나기 전에 지문이
--   우연히 맞은 것으로 보인다.  그래서 지문이 **연속 30 프레임** 유지된 뒤부터 센다.
--
-- 아무것도 안 쓴다.  평소처럼 진행하면 된다.
-- 출력  로그 + C:/snatcher/dump/probe_hole_content_0_1_1_<날짜>.tsv

local MEM = emu.memType.pceMemory
local LO, HI = 0x7FA0, 0x7FEB
local SIZE = HI - LO + 1               -- 76
local NEED = 32                        -- 상주부 크기
local SETTLE = 30                      -- 지문이 이만큼 이어져야 믿는다

local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local dirty = {}                       -- 오프셋 -> 처음 더러워진 프레임
local sample = {}                      -- 오프셋 -> 그때 값
local streak, liveA = 0, 0
local kinds, seen = 0, {}
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

-- 연속으로 깨끗한 가장 긴 구간
local function best_run()
  local best_at, best_len, at, len = -1, 0, -1, 0
  for i = 0, SIZE - 1 do
    if dirty[i] then
      at, len = -1, 0
    else
      if at < 0 then at = i end
      len = len + 1
      if len > best_len then best_at, best_len = at, len end
    end
  end
  return best_at, best_len
end

local function map_text()
  local row = {}
  for i = 0, SIZE - 1 do row[#row+1] = dirty[i] and 'X' or '.' end
  return table.concat(row)
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_hole_content_0_1_1_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:write('\n더러운 바이트\naddr\tfirst_frame\tvalue\n')
  for i = 0, SIZE - 1 do
    if dirty[i] then
      f:write(string.format('%04X\t%d\t%02X\n', LO + i, dirty[i], sample[i] or 0))
    end
  end
  f:close()
end

emu.addEventCallback(function()
  if not overlayA() then streak = 0; return end
  streak = streak + 1
  if streak < SETTLE then return end          -- 로드가 끝나기를 기다린다
  liveA = liveA + 1

  local body, key = {}, {}
  for i = 0, SIZE - 1 do
    local v = emu.read(LO + i, MEM) or 0
    body[i] = v
    key[#key+1] = string.format('%02X', v)
    if v ~= 0xFF and not dirty[i] then
      dirty[i] = liveA
      sample[i] = v
    end
  end

  local fingerprint = table.concat(key)
  if not seen[fingerprint] then seen[fingerprint] = liveA; kinds = kinds + 1 end

  if liveA % 600 == 0 or liveA == 1 then
    local at, len = best_run()
    local n = 0
    for _ in pairs(dirty) do n = n + 1 end
    say(string.format('--- 오버레이A %d --- 더러운 바이트 %d/%d · 내용 %d 가지',
                      liveA, n, SIZE, kinds))
    say(string.format('    %s   ($%04X 부터)', map_text(), LO))
    if len >= NEED then
      say(string.format('    ★ 깨끗한 최장 구간 $%04X-$%04X %d B  -- 상주부 %d B 들어간다',
                        LO + at, LO + at + len - 1, len, NEED))
    else
      say(string.format('    ★ 깨끗한 최장 구간 %d B 뿐 -- 상주부 %d B 가 안 들어간다',
                        len, NEED))
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_HOLE_CONTENT 0.1.1 loaded  --  아무것도 안 쓴다')
emu.log('  0.1.0 은 76 B 로 판정하고 16 B 만 찍어서 어디가 더러운지 못 봤다')
emu.log('  이번엔 바이트별 지도를 낸다.  . = 깨끗 · X = 한 번이라도 FF 가 아니었다')
emu.log('  깨끗한 최장 구간이 32 B 이상이면 거기 상주부를 굽는다')
