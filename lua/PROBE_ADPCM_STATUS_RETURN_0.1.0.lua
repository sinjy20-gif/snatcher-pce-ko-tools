-- Passive AD_STAT return-value probe.
--
-- $F6DB is System Card AD_STAT.  Its common return point is $F6F4 (RTS),
-- where A is the exact status value seen by the game's caller.  This script
-- records value changes and the first samples around each ADPCM playing-edge;
-- it never writes any emulated state.

local OUT = "C:/snatcher/dump/probe_adpcm_status_return_0_1_0.tsv"
local mem, cpu = emu.memType.pceMemory, emu.memType.cpu
local RETURN = 0xF6F4
local frame, wasPlaying, edgeFrame, samplesAfterEdge = 0, false, -999999, 0
local lastKey = ""
local file = assert(io.open(OUT, "w"))
file:write("frame\tplaying\ta\tx\t1803\t180c\t180d\tnote\n")

local function rb(address) return emu.read(address, mem) or 0 end
local function hx(value) return string.format("%02X", value or 0) end

emu.addMemoryCallback(function()
  local state = emu.getState() or {}
  local playing = state["cdrom.adpcm.playing"] == true
  local a, x = state["cpu.a"] or state.a or 0, state["cpu.x"] or state.x or 0
  local key = table.concat({playing and "1" or "0", hx(a), hx(x), hx(rb(0x1803)),
                            hx(rb(0x180C)), hx(rb(0x180D))}, ":")
  local nearEdge = frame - edgeFrame <= 8
  if key ~= lastKey or nearEdge then
    file:write(string.format("%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", frame,
      playing and "1" or "0", hx(a), hx(x), hx(rb(0x1803)), hx(rb(0x180C)),
      hx(rb(0x180D)), nearEdge and "near playing edge" or "status change"))
    file:flush()
    lastKey = key
  end
end, emu.callbackType.exec, RETURN, RETURN, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  local state = emu.getState() or {}
  local playing = state["cdrom.adpcm.playing"] == true
  if playing ~= wasPlaying then
    edgeFrame, samplesAfterEdge = frame, 0
    emu.log(string.format("AD_STAT probe playing edge f%d -> %s", frame, tostring(playing)))
  end
  if frame - edgeFrame <= 8 then samplesAfterEdge = samplesAfterEdge + 1 end
  wasPlaying = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function() file:close() end, emu.eventType.scriptEnded)
emu.log("PROBE_ADPCM_STATUS_RETURN 0.1.0 loaded (passive)")
emu.log("  run one voice through its end; output: " .. OUT)
