-- Safe renderer-state census for the proven lifecycle v0.1.5 BIOS.
-- No VDC port callbacks and no emulated writes: it samples Mesen state only
-- after the verified E6800_0E ADPCM start, then snapshots the live SATB.

local OUT = "C:/snatcher/dump/probe_subtitle_render_state_0_1_0.tsv"
local mem, vram, cpu = emu.memType.pceMemory, emu.memType.pceVideoRam, emu.memType.cpu
local frame, active, dumpedKeys = 0, nil, false
local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\ta\tb\tc\tnote\n")

local function rb(a) return emu.read(a, mem) or 0 end
local function vw(w) return (emu.read(w * 2, vram) or 0) + 256 * (emu.read(w * 2 + 1, vram) or 0) end
local function matched() return rb(0x22A6) == 0 and rb(0x22A7) == 0x68 and rb(0x22AA) == 0x0E end
local function row(k, a, b, c, note) file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n", k, frame, tostring(a or ""), tostring(b or ""), tostring(c or ""), note or "")) end

local function snapshotSat(s, note)
  local base = s["vdc.satbBlockSrc"] or 0x1000
  row("satb", string.format("%04X", base), s["vdc.memAddrWrite"], "", note)
  for i = 0, 15 do
    local w = base + i * 4
    row("sat", i, string.format("%04X,%04X", vw(w), vw(w + 1)), string.format("%04X,%04X", vw(w + 2), vw(w + 3)), note)
  end
end

emu.addMemoryCallback(function()
  if active or not matched() then return end
  active = { start = frame, sawPlaying = false }
  row("start", "E6800_0E", "", "", "AD_PLAY matched")
  emu.log("render-state probe START E6800_0E")
end, emu.callbackType.exec, 0xF61A, 0xF61A, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  if not active then return end
  local s = emu.getState() or {}
  if not dumpedKeys then
    dumpedKeys = true
    local names = {}
    for k in pairs(s) do
      local low = string.lower(k)
      if string.find(low, "vdc") or string.find(low, "sat") or string.find(low, "sprite") then names[#names + 1] = k end
    end
    table.sort(names)
    for _, k in ipairs(names) do if type(s[k]) ~= "table" then row("key", k, s[k], "", "state key") end end
    snapshotSat(s, "first active frame")
  end
  if s["cdrom.adpcm.playing"] == true then active.sawPlaying = true end
  if frame % 20 == 0 then row("state", s["vdc.satbBlockSrc"], s["vdc.memAddrWrite"], s["vdc.scanline"], "active sample") end
  if active.sawPlaying and s["cdrom.adpcm.playing"] ~= true then
    snapshotSat(s, "first frame after ADPCM end")
    row("end", active.start, frame, "", "done")
    file:flush(); emu.log("render-state probe END"); active = nil
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function() file:close() end, emu.eventType.scriptEnded)
emu.log("PROBE_SUBTITLE_RENDER_STATE 0.1.0 loaded (safe/passive)")
emu.log("  run E6800_0E once; output: " .. OUT)
