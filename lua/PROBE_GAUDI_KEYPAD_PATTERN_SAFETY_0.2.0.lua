-- GAUDI KEYPAD PATTERN SAFETY 0.2.0
-- Read-only. Load before entering the Gaudi keypad, then move through the
-- keypad and back out once. It collects BG ($0000 BAT, 64x64) and latched
-- Sprite RAM pattern references, so new 8x16 keypad slots do not steal a
-- pattern used by sprites or a transition screen.
-- Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS.

local VRAM, SPR = emu.memType.pceVideoRam, emu.memType.pceSpriteRam
local OUT = "C:/snatcher/dump/gaudi_keypad_pattern_safety_v020.tsv"
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
  emu.log("GAUDI KEYPAD PATTERN SAFETY 0.2.0 -> " .. OUT .. " (" .. reason .. ")")
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame - last_scan >= 10 then last_scan = frame; scan() end
  if frame >= 1800 then dump("30_seconds") end
end, emu.eventType.endFrame)
emu.addEventCallback(function() dump("script_stopped") end, emu.eventType.scriptEnded)
emu.log("GAUDI KEYPAD PATTERN SAFETY 0.2.0 loaded (read-only; 30s capture)")
