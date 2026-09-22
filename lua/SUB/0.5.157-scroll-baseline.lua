-- SUB 0.5.157 -- 스크롤 수열을 서명으로 묶어 센다.  엔진과 무관  ★대조군 채집용
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 새로 만드나
-- ---------------------------------------------------------------------------
-- `0.5.156` 은 `COUNT_OK($5C02)` 즉 **우리 렌더러가 돌 때만** 보고한다.
-- 그래서 원본 일본판 BIOS 로 띄우면 렌더러가 없어 **로그가 한 줄도 안 나온다.**
-- 대조군을 못 뜬다.
--
-- 그리고 `0.5.156` 이 아무 차이도 못 낸 이유가 하나 더 있다:
--     국장실 뒷화면 소환은 **지속되는** 증상이라 "바로 앞 프레임" 도 똑같이
--     망가져 있다.  둘 다 깨진 것을 비교했으니 0 이 나온 것이다.
--
-- 그래서 이 판은
--     1) 엔진에 의존하지 않고 **매 프레임** 스크롤 쓰기를 모으고
--     2) 한 프레임의 수열을 **서명 한 줄**로 만들어 개수를 센다
--
-- 쓰는 법 -- 두 번 돌려 표를 대조한다
-- ---------------------------------------------------------------------------
--     (가) 우리 빌드   BIOS build/patch/0.4.6.72/Syscard3_galmuri_0.4.6.72.pce
--     (나) 대조군     BIOS Mesen_2.2.1_Windows/Firmware/
--                          [BIOS] Super CD-ROM System (Japan) (v3.0).pce.JP_ORIGINAL
--                     ★ 명시적으로 그 파일을 고를 것 (우리 빌드로 덮여 있을 수 있다)
--     디스크는 둘 다 같은 [KO] CUE.  같은 국장실 장면을 지난다.
--     대조군에서는 한글 자막이 안 나온다 -- 그게 정상이고 그래서 대조군이다.
--
-- 판정
--     수열이 같다   -> 스크롤은 무죄.  화면이 밀리는 것은 다른 기전이다
--     수열이 다르다 -> ★ 그 차이가 곧 답
--
-- ★ 상한에 걸리면 반드시 "잘림" 을 남긴다 (인계서 §2-1 규칙)
--
-- 산출물  C:/snatcher/dump/scroll_base_0_5_157_<시각>.tsv
--         종료(스크립트 언로드) 때 서명 표를 로그로 낸다

local REPORT_EVERY = 600      -- 이만큼 프레임마다 중간 표를 낸다
local MAXT = 48               -- 한 프레임 쓰기 상한

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/scroll_base_0_5_157_' .. STAMP .. '.tsv'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local out = io.open(PATH, 'w')
out:write('frame\tn\ttrunc\tsignature\n')
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

local selReg, trace, truncated = 0, {}, false

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value return end
  if selReg ~= 0x07 and selReg ~= 0x08 then return end
  if #trace >= MAXT then truncated = true return end
  trace[#trace + 1] = {
    line = scanline(),
    reg = (selReg == 0x07) and 'BXR' or 'BYR',
    half = (port == 2) and 'lo' or 'hi',
    value = value,
  }
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local frame, sigs, order = 0, {}, {}

local function report(tag)
  local rows = {}
  for s, n in pairs(sigs) do rows[#rows + 1] = { sig = s, n = n } end
  table.sort(rows, function(a, b) return a.n > b.n end)
  say(('== %s · 프레임 %d · 서로 다른 수열 %d 가지 =='):format(tag, frame, #rows))
  for i = 1, math.min(#rows, 8) do
    say(('   n=%-6d %s'):format(rows[i].n, rows[i].sig))
  end
  if #rows > 8 then say(('   ... 그 외 %d 가지 ★잘림'):format(#rows - 8)) end
end

emu.addEventCallback(function()
  frame = frame + 1
  if #trace > 0 then
    local parts = {}
    for i, w in ipairs(trace) do
      parts[i] = ('%d:%s%s=%d'):format(w.line, w.reg, w.half, w.value)
    end
    local sig = table.concat(parts, ' ')
    if sigs[sig] == nil then order[#order + 1] = sig end
    sigs[sig] = (sigs[sig] or 0) + 1
    out:write(('%d\t%d\t%s\t%s\n'):format(frame, #trace, truncated and '★잘림' or '', sig))
    out:flush()
  end
  trace, truncated = {}, false
  if frame % REPORT_EVERY == 0 then report('중간') end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  report('최종')
  out:close()
end, emu.eventType.scriptEnded)

say('SUB 0.5.157-scroll-baseline armed -- 엔진과 무관 · 매 프레임 채집')
say('  ★ 우리 빌드와 원본 BIOS 에서 각각 돌려 서명 표를 대조한다')
say('  ' .. PATH)
