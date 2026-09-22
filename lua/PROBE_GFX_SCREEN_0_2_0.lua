-- 전면 그래픽 화면 연속 수집기 0.2.1 (저부하판)
--
-- ★ 순수 관측. 게임 메모리와 VRAM에는 아무것도 쓰지 않는다.
-- ★ Lua를 Stop하지 않는다. 번역할 그림 화면에서 G를 한 번 누르면 현재
--   VRAM 64 KB와 CRAM 512 B를 저장하고 게임을 계속한다.
--
-- 쓰는 법
-- -------
--   1) Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 켜기
--   2) 이 스크립트를 한 번 연다
--   3) 번역할 그림 화면이 완전히 나타나면 G를 한 번 누른다
--   4) 다음 화면으로 진행하고 다시 G를 누른다
--
-- 산출물
-- -------
--   C:/snatcher/dump/gfx_YYYYMMDD_HHMMSS_NNN.vram.bin  64 KB
--   C:/snatcher/dump/gfx_YYYYMMDD_HHMMSS_NNN.cram.bin  512 B
--   C:/snatcher/dump/gfx_YYYYMMDD_HHMMSS_NNN.meta.tsv  화면 시각/상태
--   C:/snatcher/dump/gfx_capture_index.tsv              전체 수집 목록
--
-- 한 번 누른 동안 한 장만 저장한다. 키를 놓았다 다시 눌러야 다음 장을 뜬다.

local VRAM = emu.memType.pceVideoRam
local CRAM = emu.memType.pcePaletteRam

local VRAM_BYTES = 0x10000
local CRAM_BYTES = 0x0200
local OUT_DIR = "C:/snatcher/dump"
local INDEX = OUT_DIR .. "/gfx_capture_index.tsv"

local frame = 0
local captures = 0
local held = false
local lastBase = ""

local function say(message)
  emu.log(message)
  print(message)
end

local function fileExists(path)
  local f = io.open(path, "rb")
  if f == nil then return false end
  f:close()
  return true
end

local function dumpMemory(path, memType, count)
  local f = io.open(path, "wb")
  if f == nil then
    say("★ 파일 열기 실패: " .. path)
    return false
  end

  -- emu.read 를 65,536번 부르는 것이 수집 순간의 긴 멈춤을 만들었다.
  -- Mesen의 벌크 API가 있으면 메모리를 한 번에 받아 파일만 조각내 쓴다.
  -- 구형 빌드에서는 기존 낱개 읽기로 자동 후퇴한다.
  local bulk = nil
  if emu.getMemoryState ~= nil then
    local ok, value = pcall(emu.getMemoryState, memType)
    if ok and type(value) == "table" and #value >= count then bulk = value end
  end

  for first = 0, count - 1, 4096 do
    local last = math.min(count - 1, first + 4095)
    local chunk = {}
    for address = first, last do
      local value = bulk ~= nil and bulk[address + 1] or emu.read(address, memType)
      chunk[#chunk + 1] = string.char((value or 0) % 256)
    end
    f:write(table.concat(chunk))
  end
  f:close()
  return true
end

local function stateValue(state, key)
  local value = state and state[key] or nil
  if type(value) == "number" then return tostring(math.floor(value)) end
  if type(value) == "boolean" then return value and "1" or "0" end
  if type(value) == "string" then return value end
  return ""
end

local function capture()
  captures = captures + 1
  local stamp = (os ~= nil and os.date ~= nil) and os.date("%Y%m%d_%H%M%S") or "session"
  local serial = captures
  local base
  repeat
    base = string.format("%s/gfx_%s_%03d", OUT_DIR, stamp, serial)
    serial = serial + 1
  until not fileExists(base .. ".vram.bin") and not fileExists(base .. ".cram.bin")

  local vramOk = dumpMemory(base .. ".vram.bin", VRAM, VRAM_BYTES)
  local cramOk = dumpMemory(base .. ".cram.bin", CRAM, CRAM_BYTES)
  if not vramOk or not cramOk then
    say("★ 수집 실패 -- 게임은 계속 진행해도 된다")
    return
  end

  local ok, state = pcall(function() return emu.getState() end)
  if not ok or type(state) ~= "table" then state = {} end

  local meta = io.open(base .. ".meta.tsv", "wb")
  if meta ~= nil then
    meta:write("key\tvalue\n")
    meta:write("frame\t" .. tostring(frame) .. "\n")
    meta:write("cdrom.scsi.sector\t" .. stateValue(state, "cdrom.scsi.sector") .. "\n")
    meta:write("cdrom.audioPlayer.currentSector\t"
      .. stateValue(state, "cdrom.audioPlayer.currentSector") .. "\n")
    meta:write("vdc.memAddrWrite\t" .. stateValue(state, "vdc.memAddrWrite") .. "\n")
    meta:close()
  end

  local newIndex = not fileExists(INDEX)
  local index = io.open(INDEX, "ab")
  if index ~= nil then
    if newIndex then
      index:write("capture\tframe\tstamp\tbase\tsector\taudio_sector\tnote\n")
    end
    index:write(string.format("%d\t%d\t%s\t%s\t%s\t%s\t\n",
      captures, frame, stamp, base,
      stateValue(state, "cdrom.scsi.sector"),
      stateValue(state, "cdrom.audioPlayer.currentSector")))
    index:close()
  end

  lastBase = base
  say(string.format("★ GFX 수집 #%d f%d -> %s.{vram,cram}.bin",
    captures, frame, base))
end

-- Mesen 판에 따라 키 이름 표기가 다를 수 있으므로 실제로 불리언을 돌려주는
-- 이름만 채택한다. 다른 글자로 물러나면 사용자가 무엇을 눌러야 할지 달라지므로
-- G 계열만 확인한다.
local KEY_NAMES = { "G", "g", "KeyG" }
local captureKey = nil
for _, name in ipairs(KEY_NAMES) do
  local ok, value = pcall(function() return emu.isKeyPressed(name) end)
  if ok and type(value) == "boolean" then
    captureKey = name
    break
  end
end

emu.addEventCallback(function()
  frame = frame + 1

  -- 키는 네 프레임마다만 본다. G를 보통 누르는 시간보다 훨씬 짧은 간격이고,
  -- 대기 중에는 Lua 호출 비용을 거의 만들지 않는다.
  if frame % 4 ~= 0 then return end

  local down = false
  if captureKey ~= nil then
    down = emu.isKeyPressed(captureKey) == true
  end

  if down and not held then capture() end
  held = down
end, emu.eventType.endFrame)

if captureKey == nil then
  say("★ Mesen에서 G 키 이름을 인식하지 못했다. 수집은 동작하지 않는다")
else
  say("PROBE GFX SCREEN 0.2.1 저부하판 -- Stop 없이 연속 수집")
  say("  번역할 그림이 완전히 뜨면 G를 한 번 누른다")
  say("  수집 키: " .. captureKey)
  say("  목록: " .. INDEX)
end
