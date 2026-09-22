-- PROBE GAUDI BAT WRITER 0.3.0 -- 자판 타일맵이 어디서 오는가.  ★순수 관측 · 쓰기 0 B
--
-- 0.2.0 이 알려준 것 (2026-09-14 실측)
--   감시 칸 5 개가 **한 프레임에 동시에** 최종값으로 바뀌었다.
--   그런데 VRAM 쓰기 콜백은 **0 건**이었다.  CPU 가 한 칸씩 쓰는 것이 아니라
--   통째로 올라간다 -- VDC 블록 전송이거나 CD -> VRAM 직접 전송이다.
--   그러면 원본이 어딘가에 타일맵 모양 그대로 있다는 뜻이고, 그것을 찾으면
--   제자리 치환으로 끝난다.
--
-- 이번에 잡는 것
--   1) 바뀌는 프레임의 **직전/직후 BAT 8 KB** -> 얼마나 한꺼번에 바뀌는지
--   2) 그 순간의 VDC 블록 전송 레지스터 (blockSrc/blockDst/blockLen)
--   3) CD SCSI 상태 (섹터·읽는 중인지) -> CD 직접 전송이면 섹터가 곧 디스크 위치다
--   4) VRAM 전체 64 KB 직후 덤프 -> 원본이 VRAM 다른 자리에 있으면 거기서 찾는다
--
-- 쓰는 법  로드 -> 자판을 **떠났다가 다시 들어가고** -> Stop
-- 산출물   C:/snatcher/dump/gaudi_batsrc_v030_*.bin / _log.txt

local VRAM = emu.memType.pceVideoRam
local BASE = "C:/snatcher/dump/gaudi_batsrc_v030"
local BAT_W = 64
local WATCH = { 34 * BAT_W + 20, 35 * BAT_W + 16, 36 * BAT_W + 4,
                33 * BAT_W + 4, 37 * BAT_W + 4 }
local BAT_BYTES = 0x2000

local frame, fired, prev, last = 0, false, nil, {}
local log = {}

local function rb(at) return emu.read(at, VRAM) or 0 end
local function grab(n)
  local t = {}
  for i = 0, n - 1 do t[i + 1] = string.char(rb(i)) end
  return table.concat(t)
end
local function save(name, data)
  local f = assert(io.open(BASE .. "_" .. name .. ".bin", "wb"))
  f:write(data); f:close()
end
local function st()
  local ok, s = pcall(emu.getState)
  return (ok and s) or {}
end
local function say(m) log[#log + 1] = m; emu.log(m) end

emu.addEventCallback(function()
  frame = frame + 1
  local changed = false
  for _, word in ipairs(WATCH) do
    local v = rb(word * 2) | (rb(word * 2 + 1) << 8)
    if last[word] ~= nil and last[word] ~= v then changed = true end
    last[word] = v
  end

  if changed and not fired then
    fired = true
    local s = st()
    local now = grab(BAT_BYTES)
    if prev then save("bat_before", prev) end
    save("bat_after", now)
    -- VRAM 전체: 원본 타일맵이 VRAM 다른 자리에 준비돼 있으면 여기서 찾는다
    save("vram_after", grab(0x10000))
    say(string.format("★ 자판 타일맵이 프레임 %d 에 바뀌었다", frame))
    local n = 0
    if prev then
      for i = 1, BAT_BYTES do
        if prev:byte(i) ~= now:byte(i) then n = n + 1 end
      end
      say(string.format("   BAT 8 KB 중 %d B 가 한 프레임에 바뀌었다", n))
    end
    for _, k in ipairs({ "vdc.blockSrc", "vdc.blockDst", "vdc.blockLen",
                         "vdc.satbBlockSrc", "vdc.memAddrWrite", "vdc.vramAddrIncrement",
                         "vdc.vramTransferDone", "vdc.vramVramIrqEnabled",
                         "cdrom.scsi.sector", "cdrom.scsi.sectorsToRead",
                         "cdrom.scsi.readSectorCounter", "cdrom.scsi.dataPort",
                         "cpu.pc", "memoryManager.mpr[3]", "memoryManager.mpr[5]",
                         "memoryManager.mpr[7]" }) do
      say(string.format("   %-28s %s", k, tostring(s[k])))
    end
  end
  if not fired then prev = grab(BAT_BYTES) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = assert(io.open(BASE .. "_log.txt", "w"))
  if #log == 0 then
    f:write("자판 타일맵이 바뀌는 순간을 못 잡았다.\n")
    f:write("스크립트를 켠 채로 자판을 완전히 떠났다가 다시 들어가야 한다.\n")
  end
  for _, m in ipairs(log) do f:write(m .. "\n") end
  f:close()
  emu.log("GAUDI BAT SRC 0.3.0 -> " .. BASE .. "_log.txt  (" .. (fired and "잡음" or "못 잡음") .. ")")
end, emu.eventType.scriptEnded)

emu.log("PROBE GAUDI BAT WRITER 0.3.0 loaded -- 자판을 떠났다가 다시 들어가고 Stop")
