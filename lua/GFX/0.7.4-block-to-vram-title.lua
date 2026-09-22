-- GFX 0.7.4 -- 블록이 VRAM 어디로 올라가는지 한 줄씩 찍는다  [타이틀 메뉴용]
--
-- 0.7.0 과 같은 코드인데 **산출 경로만** 다르다.
--   0.7.0 은 dump/gfx_upload_map_070.tsv 에 쓴다 -- 그건 09-10 깁슨 작업의
--   3 MB 짜리 자료다.  타이틀에서 그대로 돌리면 그걸 덮어쓴다.
--
-- 타이틀 메뉴에서 쓰는 법
--   ★ 업로드는 타이틀 메뉴가 **뜨기 전에** 일어난다.  Power Cycle 직후에 올리고
--     타이틀 메뉴까지 간 다음 F 를 누를 것.  메뉴가 뜬 뒤에 올리면 0 줄이 나온다.
--   보고 싶은 것: MAWR 이 $6640 · $6800 으로 찍히는 줄
--
-- 왜 필요한가
-- -----------
-- 깁슨 컴퓨터 화면 아홉 장을 구웠는데 두 번 다 깨졌다.  원인은 둘 다
-- **디스크 블록과 화면(BAT)의 짝을 추정으로 맞춘 것**이었다.
--
--   1차: 훑어서 찾은 자리가 블록 시작이 아니라 다른 블록 한복판이었다
--   2차: 짝을 디스크 순서와 장수로 추정했다 -> 배치는 우리 것, 글자는 원문
--
-- 덤프로는 못 가린다.  BAT 이 걸려 있는 동안에도 타일은 바뀌기 때문이다
-- (문서가 스크롤하면서 반대쪽 절반이 새로 올라온다).  그래서 **올리는 순간**을
-- 봐야 한다.
--
-- 무엇을 보나
-- -----------
-- 압축 해제기 `$7061` 이 불릴 때마다 그 시점 MAWR(VRAM 쓰기 주소)를 적어 두고,
-- **다음 호출 때** 그 자리의 VRAM 32 바이트를 읽어 같이 남긴다.  그 32 바이트가
-- 곧 그 블록의 첫 타일이므로, 디스크 블록들의 첫 32 바이트와 대조하면
-- "어느 블록이 VRAM 어디로 갔는지" 가 한 방에 나온다.
--
--   ★ 소스 포인터를 몰라도 된다.  결과(=VRAM에 찍힌 것)로 맞춘다.
--
-- 부담
-- ----
-- `$7061` 은 화면당 수십 번이다.  VDC 포트는 레지스터 선택($0000)만 매번 보고,
-- 데이터 쓰기는 `reg ~= 0` 한 번 비교하고 바로 빠진다 (버퍼 채우기가 2 만 번인
-- 것과 달리 여기서는 비교 하나뿐이다).
--
-- ★ 화면에 아무것도 안 그린다.  게임 메모리에도 안 쓴다.  순수 관측이다.
--
-- 쓰는 법
-- -------
--   1) Mesen: Script -> Settings -> Restrictions -> Allow I/O and OS 켜기
--   2) 이 스크립트를 연다
--   3) 깁슨 컴퓨터 문서를 처음부터 끝까지 한 번 지나간다 (스크롤 다 볼 것)
--   4) F 를 누르면 지금까지 것을 파일로 내린다 (안 눌러도 100 줄마다 저장한다)
--
-- 산출물
-- ------
--   C:/snatcher/dump/gfx_upload_map_074_title.tsv
--     seq  frame  mawr  mpr7  vram32
--         mawr   = VRAM **워드** 주소 (타일번호 = mawr / 16)
--         vram32 = 그 자리 32 바이트 (블록의 첫 타일)

local OUT = "C:/snatcher/dump/gfx_upload_map_074_title.tsv"
local DECOMP = 0x7061

local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local rows = {}
local seq = 0
local pending = nil          -- {frame, mawr, mpr7}  다음 호출 때 VRAM 을 읽는다
local reg = 0
local mawr_lo, mawr_hi = 0, 0

local function say(s) emu.log(s) end

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
  if fh == nil then say("★ 파일을 못 연다: " .. OUT) return end
  fh:write("seq\tframe\tmawr\tmpr7\tvram32\n")
  fh:write(table.concat(rows, "\n"))
  fh:write("\n")
  fh:close()
  say(string.format("  저장 %d 줄 -> %s", #rows, OUT))
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

local frame = 0                 -- 프레임 콜백에서 채운다 (getState 를 아낀다)

local function onDecompress()
  -- 앞 블록은 이제 다 써졌다.  그 자리를 읽어 한 줄 남긴다.
  flushPending()
  -- ★ getState 는 **한 번만** 부른다.  호출마다 여러 번 부르면 메센이 기어간다
  --   (예전에 실제로 그랬다).  프레임 수는 프레임 콜백이 채워 둔 것을 쓴다.
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

say("GFX 0.7.0 -- 블록 -> VRAM 자리 기록")
say("  압축 해제기 $7061 이 불릴 때마다 MAWR 과 그 자리 VRAM 32 B 를 남긴다")
say("  깁슨 문서를 처음부터 끝까지 지나가고, 다 되면 " .. tostring(KEY) .. " 를 누른다")
say("  -> " .. OUT)
