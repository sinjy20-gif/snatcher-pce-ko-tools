-- PROBE_CD_ACTIVITY 0.1.0
local cpu = emu.memType.cpu
local ADDR_BASE, ADDR_READ = 0xE006, 0xE009
local REPORT_EVERY = 300
local OUT = string.format("C:\\snatcher\\dump\\cd_activity_%s.tsv", os.date("%H%M%S"))

local frames, totalBase, totalRead = 0, 0, 0
local lastEventFrame = -1
local events = {}

local function record(kind, address)
  if kind == "BASE" then totalBase = totalBase + 1 else totalRead = totalRead + 1 end
  events[#events + 1] = {frame=frames, kind=kind, address=address}
  local gap = lastEventFrame >= 0 and string.format(" gap=%df", frames-lastEventFrame) or ""
  lastEventFrame = frames
  emu.log(string.format("CD %-4s f=%d addr=$%04X totals(base=%d read=%d)%s",
    kind, frames, address, totalBase, totalRead, gap))
end

emu.addMemoryCallback(function(a) record("BASE", a) end,
  emu.callbackType.exec, ADDR_BASE, ADDR_BASE, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(a) record("READ", a) end,
  emu.callbackType.exec, ADDR_READ, ADDR_READ, emu.cpuType.pce, cpu)

local function report()
  local file = io.open(OUT, "w")
  if not file then emu.log("failed to open "..OUT); return end
  file:write("frame\tkind\taddress\n")
  for _,e in ipairs(events) do
    file:write(string.format("%d\t%s\t$%04X\n", e.frame, e.kind, e.address))
  end
  file:write(string.format("\n# frames=%d total_base=%d total_read=%d\n",
    frames, totalBase, totalRead))
  file:close()
end

emu.addEventCallback(function()
  frames = frames + 1
  if frames % REPORT_EVERY == 0 then
    report()
    emu.log(string.format("CD SUMMARY f=%d base=%d read=%d -> %s",
      frames, totalBase, totalRead, OUT))
  end
end, emu.eventType.endFrame)

emu.log(string.format("PROBE_CD_ACTIVITY armed BASE=$%04X READ=$%04X -> %s",
  ADDR_BASE, ADDR_READ, OUT))
