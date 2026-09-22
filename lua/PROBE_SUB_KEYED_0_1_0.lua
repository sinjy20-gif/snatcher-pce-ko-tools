-- PROBE_SUB_KEYED 0.1.0 -- 열쇠 자막이 어디서 끊기는지 잡는다 (2026-08-26)
--
-- 무엇을 재려는가
-- ---------------
-- 오늘 팩을 열쇠 기반으로 다시 만들었다 (ADPCM 색인 118 조각 · 89,598 B).
-- 그런데 실기에서 자막이 안 떴다.
--
-- 정적으로 하나는 이미 잡았다: **엔진이 팩 오프셋을 빌드 때 박는다.**
--
--     기록 시작이 4699 -> 8058 로 3359 B 밀렸는데 엔진은 4699 를 보고 있었다
--     (engine_ac_timed_safe_poc.py 가 index_base/record_base 를 상수로 굽는다)
--
-- 엔진·렌더러·디스크를 다시 구웠다.  이 프로브는 그 뒤에도 안 되면 **어디서**
-- 끊기는지 가른다.  사슬이 넷이라 눈으로는 못 가른다:
--
--     1  BIOS 가 팩을 AC 에 부었나            AC $1C0000 에 "SNSB" 가 있나
--     2  헬퍼·렌더러도 올라갔나                AC $1F1C00 / $1F1F00
--     3  엔진이 박고 있는 자리가 팩과 맞나      머리에서 읽은 값과 대조
--     4  음성이 울릴 때 열쇠가 그 열쇠인가      실시간 (sector, end, rate)
--
-- 1 이 실패면 적재 경로, 3 이 실패면 다시 굽는 것을 잊은 것, 4 가 다르면
-- 열쇠 자체가 틀린 것이다.  셋 다 맞는데 안 뜨면 그리기 쪽이다.
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다 (디스크·BIOS 는 짝으로 -- subtitle-keyed 판)
--   2) 접수처까지 간다.  길리언 첫 대사 "본일부로..." 를 듣는다
--   3) Stop
--
-- 찾는 열쇠는 하나다 (렌더러가 아직 POC 라서):
--     ADPCM_003078_6800_0E   sector 003078 · end 6800 · rate 0E

local MEM  = emu.memType.pceMemory
local AC   = emu.memType.pceArcadeCardRam

local AC_PACK     = 0x1C0000
local AC_HELPER   = 0x1F1C00
local AC_RENDERER = 0x1F1F00
local WANT = { sector = 0x003078, endaddr = 0x6800, rate = 0x0E }

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\sub_keyed_0_1_0_" .. stamp .. ".txt"

local lines = {}
local function say(text)
  lines[#lines + 1] = text
  emu.log(text)
end

local function ac(offset)
  return emu.read(AC_PACK + offset, AC) or 0
end

local function ac_at(address, offset)
  return emu.read(address + offset, AC) or 0
end

local function u16(offset) return ac(offset) | (ac(offset + 1) << 8) end
local function u24(offset) return ac(offset) | (ac(offset + 1) << 8) | (ac(offset + 2) << 16) end
local function u32(offset) return u24(offset) | (ac(offset + 3) << 24) end

-- ---------------------------------------------------------------- 1·2·3 적재
local checked = false

local function check_pack()
  checked = true
  local magic = string.char(ac(0), ac(1), ac(2), ac(3))
  say("=== 1. AC $1C0000 (팩)")
  say(string.format("   매직 %q  %s", magic, magic == "SNSB" and "OK" or "★ 안 올라왔다"))
  if magic ~= "SNSB" then
    say("   -> 부팅 적재가 실패했다.  BIOS 와 디스크가 짝인지부터 볼 것")
    return
  end
  local version = u16(4)
  local glyph_off = u32(10)
  local index_count, index_off = u16(14), u32(16)
  local record_off = u32(26)
  say(string.format("   버전 %d · 글리프 off %d · 색인 %d 개 off %d · 기록 off %d",
                    version, glyph_off, index_count, index_off, record_off))

  say("=== 2. 헬퍼 · 렌더러")
  local hsum, rsum = 0, 0
  for i = 0, 63 do hsum = hsum + ac_at(AC_HELPER, i) end
  for i = 0, 63 do rsum = rsum + ac_at(AC_RENDERER, i) end
  say(string.format("   헬퍼 앞 64 B 합 %d  %s", hsum, hsum > 0 and "OK" or "★ 비었다"))
  say(string.format("   렌더러 앞 64 B 합 %d  %s", rsum, rsum > 0 and "OK" or "★ 비었다"))

  say("=== 3. 색인에서 찾는 열쇠를 직접 훑는다")
  local hits = 0
  for i = 0, index_count - 1 do
    local at = index_off + i * 13
    local sector = ac(at) | (ac(at + 1) << 8) | (ac(at + 2) << 16)
    local endaddr = ac(at + 3) | (ac(at + 4) << 8)
    local rate = ac(at + 5)
    if sector == WANT.sector and endaddr == WANT.endaddr and rate == WANT.rate then
      hits = hits + 1
      local rec = ac(at + 9) | (ac(at + 10) << 8) | (ac(at + 11) << 16) | (ac(at + 12) << 24)
      say(string.format("   [%d] 발견 · 시작프레임 %d · 기록 off %d",
                        i, ac(at + 7) | (ac(at + 8) << 8), rec))
    end
  end
  say(string.format("   -> %d 건 (엔진은 2 건을 기대한다)", hits))
  if hits == 0 then
    say("   ★ 팩은 올라왔는데 열쇠가 없다 -- 팩을 다시 굽고 디스크도 다시 구울 것")
  end
end

-- ---------------------------------------------------------------- 4 실시간 열쇠
local was_playing = false
local seen = 0

emu.addEventCallback(function()
  if not checked then
    -- 부팅 직후에는 아직 안 올라와 있다.  매직이 설 때까지 기다린다.
    if string.char(ac(0), ac(1), ac(2), ac(3)) == "SNSB" then check_pack() end
    return
  end

  local ok, s = pcall(emu.getState)
  if not ok or not s then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then
    -- 재생이 시작된 순간의 열쇠.  끝주소는 읽기주소+길이다.
    local read_addr = (emu.read(0x22A6, MEM) or 0) | ((emu.read(0x22A7, MEM) or 0) << 8)
    local length    = (emu.read(0x22A8, MEM) or 0) | ((emu.read(0x22A9, MEM) or 0) << 8)
    local rate      = emu.read(0x22AA, MEM) or 0
    local sector    = s["cdrom.scsi.sector"] or -1
    local endaddr   = (read_addr + length) & 0xFFFF
    seen = seen + 1
    local match = (sector == WANT.sector and endaddr == WANT.endaddr and rate == WANT.rate)
    say(string.format("[음성 %d] sector %06X · end %04X · rate %02X  %s",
                      seen, sector, endaddr, rate, match and "  <<< 찾는 그것" or ""))
  end
  was_playing = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if not checked then
    say("★ 팩 매직이 한 번도 안 섰다 -- AC 에 아무것도 안 올라왔다")
  end
  say(string.format("\n음성 %d 번 울렸다", seen))
  local file = io.open(PATH, "w")
  if file ~= nil then
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    emu.log("SUB KEYED 보고서 -> " .. PATH)
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE_SUB_KEYED 0.1.0 -- 접수처 첫 대사까지 간 뒤 Stop")
emu.log("  찾는 열쇠 ADPCM_003078_6800_0E")
emu.log("  -> " .. PATH)
