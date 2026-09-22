-- PROBE_CD_SECTOR 0.1.2 -- ADPCM 을 싣는 BIOS 호출을 찾는다 (2026-08-26)
--
-- 0.1.1 이 답한 것 (2026-08-26)
-- ---------------------------
-- 재생 **직전**에 불리는 BIOS 는 `$E03C` `$E045` `$E02D` `$E01B` 인데 전부 재생
-- 명령 계열이고 섹터를 안 들고 있다.  즉 **적재는 훨씬 전에 끝난다.**
--
--     음성 3·4·5 재생 = 프레임 6223·6443·6644
--     그 데이터는 그보다 한참 앞에 실렸다
--
-- 0.1.1 은 최근 60 호출만 봤다.  그래서 이 판은 **창을 없애고 전체 이력을**
-- 뒤진다.  어느 호출이든 정답 섹터를 들고 있었다면 그 자리에 훅을 걸어
-- 갈무리하면 된다 (헬퍼 여유 119 B 안에 든다).
--
-- 0.1.0 이 답한 것
-- ---------------
-- `CD_READ($E009)` 는 **ADPCM 경로가 아니다.**
--
--     음성 3·4·5 가 전부 같은 CD_READ(프레임 6971)를 마지막으로 공유했고,
--     그 호출의 scsi 045D66 은 정답(003078·003083·00309D)과 아무 관계가 없다.
--
-- 정답 섹터들은 `003000` 대에 몰려 있고 음성마다 조금씩 다르다.  즉 ADPCM 은
-- 다른 경로로 실린다.  PCE CD BIOS 에는 ADPCM 전용 호출이 따로 있다.
--
-- 짐작으로 한 자리를 찍지 않는다
-- ------------------------------
-- BIOS 진입점 표를 외워서 "$E033 이 AD_TRANS 다" 라고 단정하면, 틀렸을 때
-- 아무것도 못 건진다.  그래서 **$E000-$E05F 를 3 바이트 간격으로 전부 걸고**
-- 실제로 불리는 것만 남긴다.
--
-- 각 호출에서 A/X/Y 와 제로페이지 48 B 를 남겼다가, 재생이 시작되면 그 순간의
-- 정답 sector 가 **어느 호출의 어느 자리**에 있었는지 역으로 찾는다.
--
-- 무엇이 나오면 되는가
-- --------------------
--     매번 같은 호출 · 같은 자리   -> 엔진이 그 자리를 읽어 열쇠를 만든다
--     호출은 같은데 자리가 흔들림   -> 그 호출에 훅을 걸어 갈무리한다
--     아무 데도 없음               -> 소리 자체로 구분하는 쪽으로 (차선)
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다
--   2) 접수처까지 가서 대사 서너 개를 듣는다
--   3) Stop

local MEM = emu.memType.pceMemory

local FROM, TO, STEP = 0xE000, 0xE05F, 3   -- BIOS 진입점 표
local ZP_FROM, ZP_N = 0x2000, 48

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\cd_sector_0_1_2_" .. stamp .. ".txt"

local lines = {}
local function say(text)
  lines[#lines + 1] = text
  emu.log(text)
end

local frames, voices = 0, 0
local was_playing = false
local calls = {}          -- 최근 BIOS 호출
local hits = {}           -- 진입점 -> 불린 횟수

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

local function on_call(entry)
  return function()
    hits[entry] = (hits[entry] or 0) + 1
    local s = state()
    if s == nil then return end
    local zp = {}
    for i = 0, ZP_N - 1 do zp[#zp + 1] = emu.read(ZP_FROM + i, MEM) or 0 end
    calls[#calls + 1] = {
      entry = entry, frame = frames,
      a = s["cpu.a"] or 0, x = s["cpu.x"] or 0, y = s["cpu.y"] or 0,
      zp = zp,
    }
  end
end

for entry = FROM, TO, STEP do
  emu.addMemoryCallback(on_call(entry), emu.callbackType.exec,
                        entry, entry, emu.cpuType.pce, MEM)
end

-- ---------------------------------------------------------------- 재생 순간
emu.addEventCallback(function()
  frames = frames + 1
  local s = state()
  if s == nil then return end
  local playing = s["cdrom.adpcm.playing"] == true
  if playing and not was_playing then
    voices = voices + 1
    local truth = s["cdrom.scsi.sector"] or -1
    local read_addr = (emu.read(0x22A6, MEM) or 0) | ((emu.read(0x22A7, MEM) or 0) << 8)
    local length    = (emu.read(0x22A8, MEM) or 0) | ((emu.read(0x22A9, MEM) or 0) << 8)
    say(string.format("\n[음성 %d] 프레임 %d · end %04X · 정답 sector %06X",
                      voices, frames, (read_addr + length) & 0xFFFF, truth))

    local found = false
    for i = #calls, 1, -1 do          -- ★ 전체 이력을 뒤진다
      local c = calls[i]
      local where = {}
      -- 레지스터 세 개가 24 비트를 나눠 들고 있을 수 있다 (여섯 가지 순서)
      local regs = { A = c.a, X = c.x, Y = c.y }
      for n1, v1 in pairs(regs) do
        for n2, v2 in pairs(regs) do
          for n3, v3 in pairs(regs) do
            if n1 ~= n2 and n2 ~= n3 and n1 ~= n3 then
              if (v1 | (v2 << 8) | (v3 << 16)) == truth then
                where[#where + 1] = n1 .. n2 .. n3
              end
            end
          end
        end
      end
      -- 제로페이지에 3 바이트로 놓여 있나 (양쪽 끝 순서 모두)
      for k = 1, ZP_N - 2 do
        local lo = c.zp[k] | (c.zp[k + 1] << 8) | (c.zp[k + 2] << 16)
        local hi = c.zp[k + 2] | (c.zp[k + 1] << 8) | (c.zp[k] << 16)
        if lo == truth then where[#where + 1] = string.format("zp $%04X LE", ZP_FROM + k - 1) end
        if hi == truth then where[#where + 1] = string.format("zp $%04X BE", ZP_FROM + k - 1) end
      end
      if #where > 0 then
        found = true
        say(string.format("   $%04X (프레임 %d, %d 전)  ->  %s",
                          c.entry, c.frame, frames - c.frame, table.concat(where, " · ")))
      end
    end
    if not found then
      say("   ★ 최근 BIOS 호출 어디에도 없다")
      for i = #calls, math.max(1, #calls - 3), -1 do
        local c = calls[i]
        say(string.format("      $%04X 프레임 %d · A=%02X X=%02X Y=%02X",
                          c.entry, c.frame, c.a, c.x, c.y))
      end
    end
  end
  was_playing = playing
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say(string.format("\n음성 %d 번", voices))
  say("\n불린 BIOS 진입점:")
  local list = {}
  for entry, n in pairs(hits) do list[#list + 1] = { entry = entry, n = n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  for _, e in ipairs(list) do
    say(string.format("   $%04X  %d 회", e.entry, e.n))
  end
  local file = io.open(PATH, "w")
  if file ~= nil then
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    emu.log("보고서 -> " .. PATH)
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE_CD_SECTOR 0.1.2 -- BIOS 진입점 32 개를 전부 걸었다")
emu.log("  대사 서너 개 들은 뒤 Stop.  -> " .. PATH)
