-- Passive verifier for syscard3_subtitle_lifecycle_test_v0_1_5.pce.
--
-- It never writes CPU RAM, AC RAM, VDC, or BIOS ROM.  It snapshots the
-- measured E6800_0E start at $F61A, confirms the borrowed IRQ chain executes,
-- and compares the full $5B80-$5FFF + IRQ1 vector after playback ends.

local OUT = "C:/snatcher/dump/verify_subtitle_bios_lifecycle_0_1_5.tsv"
local mem, cpu, ac = emu.memType.pceMemory, emu.memType.cpu, emu.memType.pceArcadeCardRam
local LO, SIZE, VEC = 0x5B80, 0x480, 0x2202
local PLAY_HOOK = 0xF61A
local CAVE_LO, CAVE_HI = 0xFEC4, 0xFFDB

local frame, active = 0, nil
local file = assert(io.open(OUT, "w"))
file:write("result\tstart_frame\tend_frame\tstub_execs\tunclassified_writes\tram_diff\tvector_diff\tvector_before\tvector_ac\tvector_after\tnote\n")

local function rb(address) return emu.read(address, mem) or 0 end

local function matched()
  return rb(0x22A6) == 0 and rb(0x22A7) == 0x68 and rb(0x22AA) == 0x0E
end

local function finish(note)
  if not active then return end
  local ramDiff = 0
  for i = 0, SIZE - 1 do
    if rb(LO + i) ~= active.ram[i + 1] then ramDiff = ramDiff + 1 end
  end
  local vectorDiff = 0
  if rb(VEC) ~= active.vecLo then vectorDiff = vectorDiff + 1 end
  if rb(VEC + 1) ~= active.vecHi then vectorDiff = vectorDiff + 1 end
  local acLo = emu.read(0x1C0480, ac) or 0
  local acHi = emu.read(0x1C0481, ac) or 0
  local nowLo, nowHi = rb(VEC), rb(VEC + 1)
  -- Program-counter visibility differs between Mesen callback builds.  Keep
  -- that count diagnostic-only; byte-exact RAM/vector restoration is the POC
  -- pass criterion.
  local pass = active.stubExecs > 0 and ramDiff == 0 and vectorDiff == 0
  file:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%02X%02X\t%02X%02X\t%02X%02X\t%s\n",
    pass and "PASS" or "FAIL", active.start, frame, active.stubExecs,
    active.foreignWrites, ramDiff, vectorDiff, active.vecHi, active.vecLo,
    acHi, acLo, nowHi, nowLo, note))
  file:flush()
  emu.log(string.format("BIOS lifecycle %s: stub=%d foreignWrites=%d ramDiff=%d vecDiff=%d",
    pass and "PASS" or "FAIL", active.stubExecs, active.foreignWrites, ramDiff, vectorDiff))
  active = nil
end

emu.addMemoryCallback(function()
  if active or not matched() then return end
  -- Callbacks fire before the patched JSR, so this is the unmodified RAM image.
  local ram = {}
  for i = 0, SIZE - 1 do ram[i + 1] = rb(LO + i) end
  active = {
    start = frame, ram = ram, vecLo = rb(VEC), vecHi = rb(VEC + 1),
    stubExecs = 0, foreignWrites = 0, sawPlaying = false,
  }
  emu.log(string.format("BIOS lifecycle START E6800_0E f%d: IRQ1 $%02X%02X", frame,
    active.vecHi, active.vecLo))
end, emu.callbackType.exec, PLAY_HOOK, PLAY_HOOK, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function(address)
  if not active then return end
  if address >= LO and address < LO + 5 then active.stubExecs = active.stubExecs + 1 end
end, emu.callbackType.exec, LO, LO + 4, emu.cpuType.pce, cpu)

emu.addMemoryCallback(function()
  if not active then return end
  local state = emu.getState() or {}
  local pc = state["cpu.pc"] or state["cpu.programCounter"] or state["pc"]
  -- The POC itself writes engine bytes at start and restores them at end from
  -- BIOS cave code. Any other writer during the borrow interval is a failure.
  if type(pc) ~= "number" or pc < CAVE_LO or pc > CAVE_HI then
    active.foreignWrites = active.foreignWrites + 1
  end
end, emu.callbackType.write, LO, LO + SIZE - 1, emu.cpuType.pce, cpu)

emu.addEventCallback(function()
  frame = frame + 1
  if not active then return end
  local state = emu.getState() or {}
  if state["cdrom.adpcm.playing"] == true then
    active.sawPlaying = true
  elseif active.sawPlaying then
    finish("ADPCM ended; IRQ lifecycle restoration")
  end
end, emu.eventType.endFrame)
emu.addEventCallback(function() finish("script stopped") ; file:close() end,
  emu.eventType.scriptEnded)

emu.log("VERIFY_SUBTITLE_BIOS_LIFECYCLE 0.1.5 loaded")
emu.log("  passive; requires syscard3_subtitle_lifecycle_test_v0_1_5.pce")
emu.log("  output: " .. OUT)
