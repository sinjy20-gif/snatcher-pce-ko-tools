-- PROBE GAUDI BAT WRITER 0.4.0 -- 자판 타일 번호표를 CPU 메모리에서 찾는다.
-- ★순수 관측 · 쓰기 0 B
--
-- 지금까지 확정된 것 (2026-09-14 실측)
--   · 자판 패널(행 32~39 · 열 1~30, 240 워드)이 **한 프레임에** 올라간다
--   · VDC 블록 전송 아님 (blockSrc/Dst/Len = 0)
--   · VRAM 증가값 = **64** -> 한 칸 쓰고 바로 아래 칸.  키 하나가 위·아래 두 장이니
--     CPU 가 `ST2` 로 직접 쓴다 (그래서 VRAM 쓰기 콜백에 안 걸린다)
--   · 그릴 때 MPR3 = $69 · MPR5 = $87
--   · 준비된 타일맵 사본이 VRAM 안에는 없다
--   -> 타일 번호는 CPU 가 읽을 수 있는 메모리 어딘가에 있다.  그 순간을 떠서 찾는다.
--
-- 쓰는 법  로드 -> 자판을 떠났다가 **다시 들어가고** -> Stop
-- 산출물   C:/snatcher/dump/gaudi_battbl_v040_cpu.bin    CPU 가 보는 64 KB
--          C:/snatcher/dump/gaudi_battbl_v040_log.txt    MPR 8 개 등

local MEM, VRAM = emu.memType.pceMemory, emu.memType.pceVideoRam
local BASE = "C:/snatcher/dump/gaudi_battbl_v040"
local BAT_W = 64
local WATCH = { 34 * BAT_W + 20, 35 * BAT_W + 16, 36 * BAT_W + 4,
                33 * BAT_W + 4, 37 * BAT_W + 4 }

local frame, fired, last, log = 0, false, {}, {}

local function rb(mem, at) return emu.read(at, mem) or 0 end
local function say(m) log[#log + 1] = m; emu.log(m) end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end

emu.addEventCallback(function()
  frame = frame + 1
  if fired then return end
  local changed = false
  for _, word in ipairs(WATCH) do
    local v = rb(VRAM, word * 2) | (rb(VRAM, word * 2 + 1) << 8)
    if last[word] ~= nil and last[word] ~= v then changed = true end
    last[word] = v
  end
  if not changed then return end
  fired = true

  local s = st()
  local t = {}
  for i = 0, 0xFFFF do t[i + 1] = string.char(rb(MEM, i)) end
  local f = assert(io.open(BASE .. "_cpu.bin", "wb"))
  f:write(table.concat(t)); f:close()

  say(string.format("★ 자판이 프레임 %d 에 올라왔다 -- CPU 64 KB 를 떴다", frame))
  local mpr = {}
  for i = 0, 7 do
    local v = s["memoryManager.mpr[" .. i .. "]"]
    mpr[#mpr + 1] = string.format("$%02X", (v or -1) % 256)
  end
  say("   MPR 0..7  " .. table.concat(mpr, " "))
  for _, k in ipairs({ "cpu.pc", "vdc.memAddrWrite", "vdc.vramAddrIncrement",
                       "cdrom.scsi.sector" }) do
    say(string.format("   %-24s %s", k, tostring(s[k])))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = assert(io.open(BASE .. "_log.txt", "w"))
  if #log == 0 then f:write("못 잡았다 -- 자판을 떠났다가 다시 들어가야 한다\n") end
  for _, m in ipairs(log) do f:write(m .. "\n") end
  f:close()
  emu.log("GAUDI BAT TABLE 0.4.0 -> " .. BASE .. "_log.txt  (" .. (fired and "잡음" or "못 잡음") .. ")")
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI BAT WRITER 0.4.0 loaded -- 자판 떠났다가 다시 들어가고 Stop")
