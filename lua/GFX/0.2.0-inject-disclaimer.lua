-- GFX 0.2.0 -- 면책 화면을 한국어 타일로 **실제로 바꾼다**
--
-- ⚠ 이건 관측이 아니다.  VRAM 에 쓴다.
--   지금까지 GFX 프로브(0.1.x)는 전부 순수 관측이었다.  이건 다르다.
--   디스크도 롬도 안 건드리지만 **화면은 바뀐다.**
--
-- 왜 Lua 로 먼저 하나
-- -------------------
-- 최종 형태는 6280 어셈블리로 디스패처에 붙는 것이다.  그런데 그걸 바로 짜면
-- 두 가지가 한꺼번에 의심스러워진다 -- **타일 데이터가 맞나** 와 **주입 코드가
-- 맞나**.  Lua 로 먼저 넣으면 데이터만 시험하게 된다.  틀리면 데이터 문제다.
--
-- 자막 때 이 순서를 안 지켜서 여러 번 되돌아갔다 (§25 의 0.5.8 이 그랬다).
--
-- 무엇을 넣나
-- ----------
--     build/gfx/disclaimer.tiles.bin   184 타일 · 5,888 B  -> VRAM 바이트 $2200
--     build/gfx/disclaimer.bat.tsv     672 칸              -> BAT (폭 64)
--
-- 언제 넣나 -- 지문으로 안다
-- --------------------------
-- 프레임 번호로 걸면 판마다 달라진다.  대신 **원본 타일의 지문**을 본다.
--
--     타일 $1E4 = VRAM 바이트 $3C80.  원본은 09 F6 4A B5 로 시작한다
--
-- 그 지문이 보이면 그 화면이다.  넣고 나면 지문이 사라지므로 다시 안 넣는다.
-- 게임이 원본을 다시 그리면 지문이 돌아오고, 그때 또 넣는다.
--
-- ⚠ 세이브스테이트로 들어가지 말 것.  부팅 직후 화면이라 그럴 이유도 없다.
--
-- 쓰는 법
-- -------
--   1) 이 스크립트를 먼저 연다
--   2) 부팅한다
--   3) 면책 화면이 뜨는 것을 본다
--
--   Script -> Settings -> Restrictions -> Allow I/O and OS 가 켜져 있어야 한다

local VRAM = emu.memType.pceVideoRam

local TILES = "C:/snatcher/build/gfx/disclaimer.tiles.bin"
local BATTSV = "C:/snatcher/build/gfx/disclaimer.bat.tsv"

local TILE_FIRST = 0x110
local TILE_BASE = TILE_FIRST * 32          -- $2200
local BAT_WIDTH = 64

-- 원본 지문 (타일 $1E4 앞 4 바이트).  0.1.0 덤프에서 실측.
local SIG_AT = 0x1E4 * 32
local SIG = { 0x09, 0xF6, 0x4A, 0xB5 }

local function say(m) emu.log(m); print(m) end

-- ---------------------------------------------------------------- 자료 읽기

local function readTiles()
  local f = io.open(TILES, "rb")
  if f == nil then return nil, "타일 파일이 없다: " .. TILES end
  local data = f:read("*all")
  f:close()
  return data
end

local function readBat()
  local f = io.open(BATTSV, "r")
  if f == nil then return nil, "BAT 파일이 없다: " .. BATTSV end
  local cells = {}
  local first = true
  for line in f:lines() do
    if first then
      first = false                         -- 머리줄
    else
      local row, col, tile = line:match("^(%d+)\t(%d+)\t(%x+)")
      if row ~= nil then
        cells[#cells + 1] = { tonumber(row), tonumber(col), tonumber(tile, 16) }
      end
    end
  end
  f:close()
  return cells
end

local tiles, tilesError = readTiles()
local cells, batError = readBat()
if tiles == nil then say("★ " .. tilesError); return end
if cells == nil then say("★ " .. batError); return end

say(string.format("GFX 0.2.0 -- 타일 %d B (%d 개) · BAT %d 칸",
                  #tiles, #tiles // 32, #cells))
say("  부팅해서 면책 화면을 기다려라.  지문이 보이면 자동으로 바꾼다")

-- ---------------------------------------------------------------- 주입

local injected = 0
local frame = 0

local function signaturePresent()
  for index, want in ipairs(SIG) do
    if emu.read(SIG_AT + index - 1, VRAM) ~= want then return false end
  end
  return true
end

-- ★ 지문 자리($3C80 · 타일 $1E4)는 **우리가 덮는 범위($2200-$38FF) 밖**이다.
--   그래서 넣고 나서도 지문이 그대로 남는다 -- 그것만 보고 넣으면 매 프레임
--   다시 넣게 된다.  우리 첫 타일이 이미 앉아 있는지 따로 본다.
--   (덮는 범위를 넓혀 지문을 포함시킬 수도 있지만, 그러면 원본 타일을 더 지워야
--    한다.  쓰지도 않는 자리를 건드릴 이유가 없다.)
local function alreadyInjected()
  for index = 1, 4 do
    if emu.read(TILE_BASE + index - 1, VRAM) ~= tiles:byte(index) then
      return false
    end
  end
  return true
end

local function inject()
  for offset = 1, #tiles do
    emu.write(TILE_BASE + offset - 1, tiles:byte(offset), VRAM)
  end
  for _, cell in ipairs(cells) do
    local at = (cell[1] * BAT_WIDTH + cell[2]) * 2
    emu.write(at, cell[3] % 256, VRAM)
    emu.write(at + 1, (cell[3] // 256) % 16, VRAM)      -- 팔레트 0
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  if signaturePresent() and not alreadyInjected() then
    inject()
    injected = injected + 1
    say(string.format("★f%d  면책 화면을 바꿨다 (%d 번째)", frame, injected))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  if injected == 0 then
    say("한 번도 안 바꿨다 -- 지문을 못 봤다")
    say(string.format("  타일 $1E4 (VRAM $%04X) 가 %02X %02X %02X %02X 인지 확인할 것",
                      SIG_AT, SIG[1], SIG[2], SIG[3], SIG[4]))
    say("  그 화면을 안 지났거나, 세이브스테이트로 들어왔을 수 있다")
  else
    say(string.format("바꾼 횟수 %d", injected))
  end
end, emu.eventType.scriptEnded)
