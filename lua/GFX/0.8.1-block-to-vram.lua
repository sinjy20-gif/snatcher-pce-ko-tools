-- GFX 0.8.1 -- 디스크 블록이 VRAM 어디로 올라가는지 찍는다  [장면 이름만 바꿔 쓴다]
--
-- 0.7.4(타이틀 전용)를 일반화한 판.  바뀐 것은 **산출 경로에 LABEL 이 붙는다**는 것뿐이다.
-- 0.7.0 은 `dump/gfx_upload_map_070.tsv` 에 쓰는데 그건 09-10 깁슨 작업 자료다.
-- 다른 화면에서 그대로 돌리면 그것을 덮는다 (실제로 한 번 덮었다).
--
-- 왜 필요한가
-- -----------
-- 압축 코덱이 **아무 타일 경계에서나 이어 풀린다.**  그래서 디스크를 훑어 찾은
-- 자리가 블록 시작처럼 보여도 사실은 다른 블록의 **재개점**일 수 있다.
-- 타이틀에서 실제로 그랬다 -- `$6640` 이 그럴듯하게 풀렸지만 MAWR 로그에는
-- 업로드가 **0 회**였고, 진짜 블록은 `$6000`(193 회) 과 `$6800`(222 회) 이었다.
--
--   ★ "풀어보니 그림이 맞더라" 는 근거가 아니다.  **올리는 순간**을 봐야 한다.
--
-- 무엇을 보나
-- -----------
-- 압축 해제기 `$7061` 이 불릴 때마다 그 시점 MAWR(VRAM 쓰기 주소)를 적어 두고,
-- **다음 호출 때** 그 자리의 VRAM 32 바이트를 읽어 같이 남긴다.  그 32 바이트가
-- 그 블록의 첫 타일이므로, 디스크 블록들의 첫 32 바이트와 대조하면
-- "어느 블록이 VRAM 어디로 갔는지" 가 한 방에 나온다.  소스 포인터는 몰라도 된다.
--
-- 쓰는 법
-- -------
--   1) Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 켜기
--   2) LABEL 을 장면 이름으로 바꾼다
--   3) ★ 그 장면이 **뜨기 전에** 올린다.  업로드는 화면이 그려지기 전에 끝난다 --
--      뜬 뒤에 올리면 0 줄이 나온다.  Power Cycle 직후가 제일 안전하다.
--   4) 장면을 끝까지 지나간 뒤 F 를 누른다 (안 눌러도 600 프레임마다 저장한다)
--
--   LABEL 후보:  moscow / after50 / neokobe / ending
--
-- 산출물  C:/snatcher/dump/gfx_upload_map_081_<LABEL>.tsv
--           seq  frame  mawr  mpr7  vram32
--             mawr   = VRAM **워드** 주소 (타일번호 = mawr / 16)
--             vram32 = 그 자리 32 바이트 (블록의 첫 타일)
--
-- ★ 화면에 아무것도 안 그린다.  게임 메모리에도 안 쓴다.  순수 관측이다.

local LABEL = "moscow"
local DECOMP = 0x7061

local OUT = "C:/snatcher/dump/gfx_upload_map_081_" .. LABEL .. ".tsv"
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local rows = {}
local seq = 0
local pending = nil          -- {frame, mawr, mpr7}  다음 호출 때 VRAM 을 읽는다
local reg = 0
local mawr_lo, mawr_hi = 0, 0
local frame = 0

local function readTile(word)
  local base = word * 2
  local out = {}
  for i = 0, 31 do
    out[#out + 1] = string.format("%02X", emu.read(base + i, VRAM) or 0)
  end
  return table.concat(out, " ")
end

local function flushPending()
  if pending == nil then return end
  seq = seq + 1
  rows[#rows + 1] = string.format("%d\t%d\t%04X\t%02X\t%s",
    seq, pending.frame, pending.mawr, pending.mpr7, readTile(pending.mawr))
  pending = nil
end

local function save()
  if #rows == 0 then return end
  local fh = io.open(OUT, "w")
  if fh == nil then emu.log("★ 파일을 못 연다: " .. OUT) return end
  fh:write("seq\tframe\tmawr\tmpr7\tvram32\n")
  fh:write(table.concat(rows, "\n"))
  fh:write("\n")
  fh:close()
  emu.log(string.format("  [%s] 저장 %d 줄 -> %s", LABEL, #rows, OUT))
end

-- VDC 포트.  레지스터 선택만 매번 보고, 데이터 쓰기는 바로 빠진다.
local function onPort(addr, value)
  if addr == 0x0000 then
    reg = value % 32
    return
  end
  if reg ~= 0x00 then return end          -- MAWR 이 아니면 볼 것 없다
  if addr == 0x0002 then
    mawr_lo = value
  elseif addr == 0x0003 then
    mawr_hi = value
  end
end

local function onDecompress()
  flushPending()                          -- 앞 블록은 이제 다 써졌다
  -- ★ getState 는 호출마다 **한 번만**.  여러 번 부르면 메센이 기어간다.
  local mpr7 = 0
  local ok, st = pcall(emu.getState)
  if ok and type(st) == "table" then
    mpr7 = st["cpu.mpr7"] or st["mpr7"] or 0
  end
  pending = {
    frame = frame,
    mawr = ((mawr_hi * 256) + mawr_lo) % 0x8000,
    mpr7 = mpr7,
  }
end

local KEY = nil
for _, name in ipairs({ "F", "f", "KeyF" }) do
  local ok = pcall(function() return emu.isKeyPressed(name) end)
  if ok then KEY = name break end
end

local down = false
local function onFrame()
  frame = frame + 1
  if #rows > 0 and frame % 600 == 0 then save() end   -- 10 초마다 안전 저장
  if KEY == nil then return end
  local now = emu.isKeyPressed(KEY) == true
  if now and not down then
    flushPending()
    save()
  end
  down = now
end

emu.addMemoryCallback(onPort, emu.callbackType.write, 0x0000, 0x0003, CPU)
emu.addMemoryCallback(onDecompress, emu.callbackType.exec, DECOMP, DECOMP, CPU)
emu.addEventCallback(onFrame, emu.eventType.endFrame)

emu.log("GFX BLOCK->VRAM 0.8.1  [" .. LABEL .. "]  읽기 전용")
emu.log("  ★ 장면이 뜨기 전에 올릴 것 -- 뜬 뒤에 올리면 0 줄이 나온다")
emu.log("  다 지나간 뒤 " .. tostring(KEY) .. " · 600 프레임마다 자동 저장")
emu.log("  -> " .. OUT)
