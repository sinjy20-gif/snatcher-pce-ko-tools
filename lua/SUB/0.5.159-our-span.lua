-- SUB 0.5.159 -- 우리 주입 코드가 한 프레임에서 몇 줄을 먹는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 어디까지 왔나
-- ---------------------------------------------------------------------------
-- `0.5.157`  원본은 BYR=96 을 10,016 프레임 전부 줄 32 에 쓴다.  예외 0
--            우리는 33 건이 줄 33~72 로 밀린다 -> 그 프레임만 천장이 샌다
-- `0.5.158`  밀림이 두 무리다
--              큼 (+11~+44)  n=25  ★ engine 이 **안 돈** 프레임.  소환의 정체
--              작음 (+1~2)   n=17  engine 이 돈 프레임.  거의 무해
--            ⚠ 큰 지연 25 중 **4 건은 gate 조차 안 돌았다** -- 우리 코드가
--              안 도는데도 밀린다.  "우리 armer 가 범인" 으로 단정하면 안 된다
--
-- 국장실은 래스터 분할이 3 개(줄 7·135·148)로 제일 빡빡한 장면이다.
-- 원래 여유가 없어서 조금만 얹어도 넘어간다.
--
-- 그래서 이번엔 "누가 범인이냐" 가 아니라 **"우리가 얼마나 먹느냐"** 를 잰다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     뱅크1 우리 코드 $F0EA~$FC76 이 실행된 첫 줄 · 마지막 줄 · 명령 수
--     $5B80~$5E1F (엔진/헬퍼) 가 실행된 첫 줄 · 마지막 줄 · 명령 수
--     BYR=96 이 닿은 줄
--
-- 판정
--     우리 구간이 줄 32 를 넘어 걸치는 프레임 = 밀리는 프레임    -> 줄이면 닫힌다
--     안 걸치는데도 밀린다                                       -> 게임 쪽 부하다.  우리 무죄
--     명령 수가 프레임마다 튄다                                  -> 그 튀는 원인을 찾는다
--
-- ★ exec 콜백은 명령마다 불린다.  구간이 넓으면 느려질 수 있다 --
--   숫자만 세고 스캔라인은 **처음과 끝에서만** 읽는다
--
-- 산출물  C:/snatcher/dump/our_span_0_5_159_<시각>.tsv

local BANK1_LO, BANK1_HI = 0xF0EA, 0xFC76      -- 우리 뱅크1 자리 (2,957 B)
local ENG_LO,  ENG_HI    = 0x5B80, 0x5E1F      -- 엔진/헬퍼 자리
local GOOD_LINE = 32

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/our_span_0_5_159_' .. STAMP .. '.tsv'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local out = io.open(PATH, 'w')
out:write('frame\tbyr96\tdelay\tb1_first\tb1_last\tb1_n\teng_first\teng_last\teng_n\n')
local function say(m) emu.log(m); print(m) end

local LINE_KEY
local function scanline()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return -1 end
  if LINE_KEY == nil then
    LINE_KEY = false
    for _, k in ipairs({'vdc.scanline', 'scanline', 'vdc.vCounter', 'ppu.scanline'}) do
      if type(s[k]) == 'number' then LINE_KEY = k break end
    end
  end
  if LINE_KEY == false then return -1 end
  local v = s[LINE_KEY]
  return type(v) == 'number' and math.floor(v) or -1
end

local selReg = 0
local byr96 = -1
local b1f, b1l, b1n = -1, -1, 0
local ef, el, en = -1, -1, 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  if selReg == 0x08 and port == 2 and value == 96 and byr96 < 0 then
    byr96 = scanline()
  end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

emu.addMemoryCallback(function()
  b1n = b1n + 1
  if b1f < 0 then b1f = scanline() end
  b1l = -2                                   -- 끝은 프레임 끝에서 한 번만 읽는다
end, emu.callbackType.exec, BANK1_LO, BANK1_HI, CPU, MEM)

emu.addMemoryCallback(function()
  en = en + 1
  if ef < 0 then ef = scanline() end
  el = -2
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

-- 마지막 줄은 정확도를 위해 128 명령마다 갱신한다 (매 명령 getState 는 너무 느리다)
local b1c, ec = 0, 0
emu.addMemoryCallback(function()
  b1c = b1c + 1
  if b1c % 128 == 0 then b1l = scanline() end
end, emu.callbackType.exec, BANK1_LO, BANK1_HI, CPU, MEM)
emu.addMemoryCallback(function()
  ec = ec + 1
  if ec % 128 == 0 then el = scanline() end
end, emu.callbackType.exec, ENG_LO, ENG_HI, CPU, MEM)

local frame, late, straddle = 0, 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  if b1n > 0 or en > 0 then
    local d = (byr96 >= 0) and (byr96 - GOOD_LINE) or 0
    out:write(('%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n'):format(
      frame, byr96, d, b1f, b1l, b1n, ef, el, en))
    if d > 2 then
      late = late + 1
      local cross = (b1f >= 0 and b1f <= GOOD_LINE and b1l ~= -1 and b1l > GOOD_LINE)
                 or (ef >= 0 and ef <= GOOD_LINE and el ~= -1 and el > GOOD_LINE)
      if cross then straddle = straddle + 1 end
      say(('★늦음 f%-6d +%-3d  뱅크1 줄%d~%s (%d명령)  엔진 줄%d~%s (%d명령) %s'):format(
        frame, d, b1f, b1l < 0 and '?' or tostring(b1l), b1n,
        ef, el < 0 and '?' or tostring(el), en,
        cross and '★줄32 를 넘어 걸침' or ''))
    end
  end
  byr96, b1f, b1l, b1n, ef, el, en, b1c, ec = -1, -1, -1, 0, -1, -1, 0, 0, 0
  if frame % 1800 == 0 then
    say(('== 프레임 %d · 늦음 %d · 그중 줄32 를 넘어 걸친 것 %d =='):format(
      frame, late, straddle))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.159-our-span armed -- 우리 코드가 한 프레임에서 몇 줄을 먹는가')
say('  ★ 늦은 프레임에서 우리 구간이 줄 32 를 넘어 걸치는가')
say('  ' .. PATH)
