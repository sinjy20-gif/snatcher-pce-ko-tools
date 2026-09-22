-- PROBE_CD_SECTOR 0.1.0 -- 6280 이 섹터를 볼 수 있나 (2026-08-26)
--
-- 왜 이걸 재나
-- ------------
-- 자막 열쇠는 `(sector, end_addr, rate)` 다.  실측으로 sector 가 **반드시**
-- 필요한 것이 확인됐다:
--
--     (sector, end, rate)   389 고유   <- 음성 하나하나가 갈린다
--     (end, rate)            31 고유   <- 389 개가 31 개로 뭉갠다
--     (end, rate, length)   282 고유   <- 그래도 78 조합이 충돌
--
-- 그런데 지금까지 sector 는 **에뮬레이터 상태**(`cdrom.scsi.sector`)에서만 읽었다.
-- 네이티브 엔진은 그걸 못 본다.  6280 이 볼 수 있어야 열쇠를 런타임에 만든다.
--
-- 볼 수 있을 근거는 있다 -- 섹터를 정하는 쪽이 게임이다:
--
--     docs/PRODUCTION_OVERLAY_STORAGE.md
--     "CD_READ ($E009) receives a logical sector offset"
--
-- 즉 CPU 가 인자로 넘긴다.  문제는 **ADPCM 재생 순간에도 그 값이 남아 있느냐**다.
-- 적재와 재생 사이에 다른 CD 읽기가 끼면 덮인다.  그래서 재야 한다.
--
-- 무엇을 찍나
-- -----------
--     1  CD_READ($E009) 가 불릴 때마다   그 순간 레지스터/제로페이지
--     2  ADPCM 재생이 시작될 때          그때의 cdrom.scsi.sector (정답)
--     3  둘을 시각으로 잇는다            재생 직전 CD_READ 의 인자가 정답과 같나
--
-- 3 이 맞으면 엔진이 그 자리를 읽어 열쇠를 만들 수 있다.
-- 어긋나면 다른 자리를 찾아야 한다 (또는 적재 시점에 미리 갈무리해 둬야 한다).
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다
--   2) 접수처까지 가서 대사 몇 개를 듣는다
--   3) Stop

local MEM = emu.memType.pceMemory
local CD_READ = 0xE009
local CD_BASE = 0xE006

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\cd_sector_0_1_0_" .. stamp .. ".txt"

local lines = {}
local function say(text)
  lines[#lines + 1] = text
  emu.log(text)
end

local frames = 0
local reads = {}          -- 최근 CD_READ 호출들
local voices = 0
local was_playing = false

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

-- ---------------------------------------------------------------- 1. CD_READ
-- BIOS 호출 규약은 레지스터로 인자를 받는다.  무엇이 섹터인지 아직 모르므로
-- **A/X/Y 와 제로페이지 앞부분을 통째로** 남기고 나중에 대조한다.
-- (짐작으로 한 자리만 찍으면 틀렸을 때 아무것도 못 건진다.)
emu.addMemoryCallback(function()
  local s = state()
  if s == nil then return end
  local zp = {}
  for a = 0x2000, 0x201F do zp[#zp + 1] = emu.read(a, MEM) or 0 end
  reads[#reads + 1] = {
    frame = frames,
    a = s["cpu.a"] or 0, x = s["cpu.x"] or 0, y = s["cpu.y"] or 0,
    scsi = s["cdrom.scsi.sector"] or -1,
    zp = zp,
  }
  if #reads > 40 then table.remove(reads, 1) end
end, emu.callbackType.exec, CD_READ, CD_READ, emu.cpuType.pce, MEM)

-- ---------------------------------------------------------------- 2·3 재생 순간
emu.addEventCallback(function()
  frames = frames + 1
  local s = state()
  if s == nil then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then
    voices = voices + 1
    local read_addr = (emu.read(0x22A6, MEM) or 0) | ((emu.read(0x22A7, MEM) or 0) << 8)
    local length    = (emu.read(0x22A8, MEM) or 0) | ((emu.read(0x22A9, MEM) or 0) << 8)
    local rate      = emu.read(0x22AA, MEM) or 0
    local truth     = s["cdrom.scsi.sector"] or -1
    say(string.format("\n[음성 %d] 프레임 %d · end %04X · rate %02X · 정답 sector %06X",
                      voices, frames, (read_addr + length) & 0xFFFF, rate, truth))

    -- 직전 CD_READ 들에서 정답과 같은 값이 어디 있었나
    local found = false
    for i = #reads, math.max(1, #reads - 6), -1 do
      local r = reads[i]
      local where = {}
      if r.a == ((truth >> 16) & 0xFF) then where[#where + 1] = "A(상위)" end
      if r.x == ((truth >> 8) & 0xFF) then where[#where + 1] = "X(중위)" end
      if r.y == (truth & 0xFF) then where[#where + 1] = "Y(하위)" end
      for k = 1, #r.zp - 2 do
        local v = r.zp[k] | (r.zp[k + 1] << 8) | (r.zp[k + 2] << 16)
        if v == truth then where[#where + 1] = string.format("zp $%04X", 0x2000 + k - 1) end
      end
      if #where > 0 then
        found = true
        say(string.format("   CD_READ(프레임 %d, %d 프레임 전)  정답이 있는 곳: %s",
                          r.frame, frames - r.frame, table.concat(where, " · ")))
      end
    end
    if not found then
      say("   ★ 직전 CD_READ 어디에도 정답 sector 가 없다")
      if #reads > 0 then
        local r = reads[#reads]
        say(string.format("      마지막 CD_READ: 프레임 %d · A=%02X X=%02X Y=%02X · scsi %06X",
                          r.frame, r.a, r.x, r.y, r.scsi))
      end
    end
  end
  was_playing = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say(string.format("\n음성 %d 번 · CD_READ %d 회 기록", voices, #reads))
  say("\n판정: '정답이 있는 곳' 이 매번 같은 자리면 -- 엔진이 거기서 읽으면 된다.")
  say("      매번 다르거나 없으면 -- 적재 시점에 갈무리하는 쪽으로 가야 한다.")
  local file = io.open(PATH, "w")
  if file ~= nil then
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    emu.log("CD SECTOR 보고서 -> " .. PATH)
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE_CD_SECTOR 0.1.0 -- 대사 몇 개 들은 뒤 Stop")
emu.log("  6280 이 sector 를 볼 수 있는지 잰다")
emu.log("  -> " .. PATH)
