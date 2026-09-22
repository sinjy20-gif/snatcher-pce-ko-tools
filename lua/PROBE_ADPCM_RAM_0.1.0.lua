-- PROBE ADPCM RAM 0.1.0 -- 음성을 ADPCM RAM 에서 직접 떠낸다
--
-- 왜
-- ---------------------------------------------------------------------------
-- 디스크에서 음성을 뽑으려 했으나 좌표가 없다.  수집기가 적어 두는 값이 전부
-- **ADPCM 하드웨어 상태**이지 디스크 위치가 아니었다 (runtime_text_audit_0.2.1):
--
--     readAddress / writeAddress   ADPCM 전용 RAM 안의 포인터
--     sector                       `cdrom.scsi.sector` -- 드라이브가 마지막에
--                                  서비스한 좌표.  그 대사의 위치가 아니다
--
-- 실측이 그것을 증명했다: 한 세션에서 12 개 이벤트가 전부 sector=002F0A 였다.
-- 서로 다른 대사인데 같은 자리를 가리킨 것이다.  그 좌표로 뽑은 클립은 대사
-- 중간에서 끊긴다 ("노도노 이타..." 하고 끊김 -- 소유자 확인 2026-08-20).
--
-- 그런데 **디스크에서 찾을 이유가 없다.**  게임이 이미 ADPCM RAM 에 적재해 두고
-- 거기서 재생한다.  재생이 시작될 때 그 RAM 을 떠내면 정확히 그 대사다.
--
-- 이 프로브가 하는 일
-- ---------------------------------------------------------------------------
--   1. ADPCM RAM 을 읽을 수 있는 메모리 타입이 있는지 확인한다
--      emu.memType 목록을 통째로 찍는다 -- 이름을 몰라 헛도는 일을 막는다
--   2. 재생이 시작되는 순간 상태를 기록한다
--      writeAddress / readAddress / length / rate
--   3. 읽을 수 있으면 그 구간을 파일로 떠낸다
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     memtype 행에 adpcm 비슷한 것이 있으면   -> 그 이름으로 덤프가 된다
--     없으면                                  -> 다른 경로를 찾아야 한다
--     start 행                                -> 재생 시작마다 한 줄
--
-- 돌리는 법: 전원 투입부터, 대사가 나오는 데까지.  Stop 을 눌러야 파일이 닫힌다.

local OUT = "C:\\snatcher\\dump\\probe_adpcm_ram_0_1_0.tsv"
local DUMP_DIR = "C:\\snatcher\\dump\\audio\\ram\\"

local file = assert(io.open(OUT, "w"))
file:write("kind\tframe\ta\tb\tc\tnote\n")

local frame, rows = 0, 0
local function row(kind, a, b, c, note)
  rows = rows + 1
  file:write(string.format("%s\t%d\t%s\t%s\t%s\t%s\n", kind, frame,
    tostring(a or ""), tostring(b or ""), tostring(c or ""), note or ""))
  file:flush()
end

-- 1. 메모리 타입 목록.  이름을 추측하지 않고 실제로 있는 것만 쓴다
local adpcmType = nil
do
  local names = {}
  for name, value in pairs(emu.memType) do
    names[#names + 1] = name
    if string.find(string.lower(name), "adpcm") then
      adpcmType = value
      row("memtype", name, tostring(value), "", "★ ADPCM 메모리 타입")
    end
  end
  table.sort(names)
  row("memtype", "(총)", #names, "", table.concat(names, " "))
  emu.log("memType 목록: " .. table.concat(names, " "))
  if adpcmType == nil then
    emu.log("★ adpcm 이름이 붙은 메모리 타입이 없다 -- 위 목록에서 후보를 골라야 한다")
  end
end

local function st()
  local ok, s = pcall(emu.getState)
  if not ok then return nil end
  return s
end

local wasPlaying, seen = false, 0

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if s == nil then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not wasPlaying then
    seen = seen + 1
    local w = s["cdrom.adpcm.writeAddress"] or -1
    local r = s["cdrom.adpcm.readAddress"] or -1
    local len = s["cdrom.adpcm.adpcmLength"] or -1
    local rate = s["cdrom.adpcm.playbackRate"] or -1
    row("start", string.format("%04X", w), string.format("%04X", r),
        string.format("%04X", len),
        string.format("rate=%02X · 재생 %d 번째", rate, seen))

    -- 3. 읽을 수 있으면 떠낸다
    if adpcmType ~= nil and len > 0 and seen <= 12 then
      local name = string.format("%sw%04X_%04X.bin", DUMP_DIR, w, len)
      local out = io.open(name, "wb")
      if out ~= nil then
        local buf = {}
        for i = 0, len - 1 do
          buf[#buf + 1] = string.char(emu.read((w + i) % 0x10000, adpcmType) or 0)
          if #buf >= 4096 then out:write(table.concat(buf)); buf = {} end
        end
        if #buf > 0 then out:write(table.concat(buf)) end
        out:close()
        row("dump", name, len, "", "떠냄")
      else
        row("dump", name, "", "", "★ 파일을 못 만든다 -- 폴더가 있는지 확인")
      end
    end
  end
  wasPlaying = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  file:write(string.format("-- 프레임 %d · 재생 %d 회 · 총 %d 행\n", frame, seen, rows))
  file:close()
end, emu.eventType.scriptEnded)

emu.log("PROBE ADPCM RAM 0.1.0")
emu.log("  전원 투입부터, 대사가 나오는 데까지.  Stop 을 눌러야 닫힌다")
emu.log("  덤프는 " .. DUMP_DIR .. " 에 (폴더가 미리 있어야 한다)")
emu.log("  출력: " .. OUT)
