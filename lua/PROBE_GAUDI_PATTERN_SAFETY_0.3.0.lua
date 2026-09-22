-- GAUDI PATTERN SAFETY 0.3.0 -- 자판 **말고 다른 화면**에서 같은 타일대를 재는 판.
--
-- 왜 (2026-09-15)
--   0.2.0 은 가우디 자판 화면 한 곳에서만 쟀다.  그 표에서 "candidate" 는
--   "이 화면이 안 쓴다" 는 뜻이지 "아무도 안 쓴다" 가 아니다.
--   실제로 $243-$24E 는 자판 화면에선 candidate 지만 **화상전화 숫자판 1~9*0#**
--   이다.  거기에 글리프를 넣고(SPLIT_SLOTS) 나머지는 0 으로 지워서
--   (clear_safe_unused) 숫자판이 통째로 날아갔다.
--
--   그래서 같은 블록을 쓰는 **다른 화면마다** 한 벌씩 재고, 빌더가 교집합만
--   안전하다고 보게 한다.
--
-- 쓰는 법
--   LABEL 을 화면 이름으로 두고 로드 -> 그 화면에 들어가 한 바퀴 -> Stop
--   화상전화면 LABEL="phone" 그대로 두면 된다.
--
-- 산출물  C:/snatcher/dump/gaudi_pattern_safety_<LABEL>_v030.tsv

local VRAM, SPR = emu.memType.pceVideoRam, emu.memType.pceSpriteRam
local LABEL = "phone"
local OUT = "C:/snatcher/dump/gaudi_pattern_safety_" .. LABEL .. "_v030.tsv"
local frame, last_scan, dumped = 0, -1, false
local seen = {}

local function rb(mem, at) return emu.read(at, mem) or 0 end
local function rw(mem, at) return rb(mem, at) | (rb(mem, at + 1) << 8) end
local function mark(pattern, source)
  local r = seen[pattern]
  if not r then r = { bg = 0, spr = 0, first = frame, last = frame }; seen[pattern] = r end
  r[source] = r[source] + 1; r.last = frame
end
local function scan()
  -- The captured Gaudi screen proved BAT base $0000 and 64 columns.
  for i = 0, 4095 do mark(rw(VRAM, i * 2) & 0x0FFF, "bg") end
  for slot = 0, 63 do
    local at = slot * 8
    local y, x, pat, attr = rw(SPR, at), rw(SPR, at + 2), rw(SPR, at + 4), rw(SPR, at + 6)
    if (y | x | pat | attr) ~= 0 then
      local base = (pat & 0x07FF) << 5
      local width = (attr & 0x0100) ~= 0 and 2 or 1
      local hc = (attr >> 12) & 3
      local height = hc == 0 and 1 or (hc == 1 and 2 or 4)
      for cell = 0, width * height - 1 do mark((base >> 4) + cell * 2, "spr") end
    end
  end
end
local function dump(reason)
  if dumped then return end
  dumped = true
  local f = assert(io.open(OUT, "w"))
  f:write("pattern\tbg_frames\tsprite_frames\tfirst_frame\tlast_frame\tstatus\n")
  for pattern = 0x200, 0x3FF do
    local r = seen[pattern]
    local bg, spr, first, last = 0, 0, "", ""
    if r then bg, spr, first, last = r.bg, r.spr, r.first, r.last end
    f:write(string.format("%03X\t%d\t%d\t%s\t%s\t%s\n", pattern, bg, spr, first, last,
      (bg == 0 and spr == 0) and "candidate" or "used"))
  end
  f:close()
  emu.log("GAUDI PATTERN SAFETY 0.3.0 [" .. LABEL .. "] -> " .. OUT .. " (" .. reason .. ")")
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame - last_scan >= 10 then last_scan = frame; scan() end
  if frame >= 1800 then dump("30_seconds") end
end, emu.eventType.endFrame)
emu.addEventCallback(function() dump("script_stopped") end, emu.eventType.scriptEnded)
emu.log("GAUDI PATTERN SAFETY 0.3.0 [" .. LABEL .. "] loaded (read-only; 30s capture)")
