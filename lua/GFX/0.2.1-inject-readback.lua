-- GFX 0.2.1 -- 왜 매 프레임 다시 넣게 되는지 가른다
--
-- ⚠ 관측이 아니다.  0.2.0 과 같이 VRAM 에 쓴다.
--
-- 0.2.0 에서 본 것
-- ----------------
-- 면책 화면이 **한국어로 바뀌었다** (2026-09-05, 실기 확인).  그런데 로그가
-- 매 프레임 "바꿨다" 를 찍었다 -- 79 번.  "이미 넣었으면 건너뛴다" 가드가
-- 한 번도 안 걸린 것이다.
--
-- 원인이 둘인데 **어셈블리로 옮길 때 완전히 달라진다**
-- ---------------------------------------------------
--     (a) 게임이 그 VRAM 을 계속 다시 올린다
--         -> 우리 코드도 **매 프레임** 써야 한다.  한 번만 쓰면 곧 지워진다
--     (b) Lua 의 emu.write / emu.read 가 어긋난다 (화면엔 반영되는데 읽으면 원본)
--         -> Lua 만의 문제다.  어셈블리는 한 번만 써도 된다
--
-- 0.1.2 의 폴링이 "60 프레임 무변화" 라고 한 것은 이것을 못 걸렀을 수 있다 --
-- 게임이 **같은 바이트를 계속 올리면** 체크섬이 안 변한다.  폴링의 맹점이었다.
--
-- 어떻게 가르나
-- ------------
--     ① 쓴 직후 같은 자리를 읽어 본다        다르면 (b) 다
--     ② 다음 프레임 **시작**에 다시 읽어 본다  거기서 원본으로 돌아가 있으면 (a) 다
--
-- 로그는 처음 몇 번과 60 프레임마다만 찍는다 (0.2.0 은 화면을 뒤덮었다).
--
-- 쓰는 법 -- 0.2.0 과 같다.  스크립트 먼저 열고 부팅, 면책 화면까지.

local VRAM = emu.memType.pceVideoRam

local TILES = "C:/snatcher/build/gfx/disclaimer.tiles.bin"
local BATTSV = "C:/snatcher/build/gfx/disclaimer.bat.tsv"

local TILE_FIRST = 0x110
local TILE_BASE = TILE_FIRST * 32          -- $2200
local BAT_WIDTH = 64

local SIG_AT = 0x1E4 * 32                  -- 원본 지문 (우리가 덮는 범위 밖이다)
local SIG = { 0x09, 0xF6, 0x4A, 0xB5 }

local function say(m) emu.log(m); print(m) end

local function readTiles()
  local f = io.open(TILES, "rb")
  if f == nil then return nil end
  local data = f:read("*all"); f:close(); return data
end

local function readBat()
  local f = io.open(BATTSV, "r")
  if f == nil then return nil end
  local cells, first = {}, true
  for line in f:lines() do
    if first then first = false else
      local row, col, tile = line:match("^(%d+)\t(%d+)\t(%x+)")
      if row ~= nil then
        cells[#cells + 1] = { tonumber(row), tonumber(col), tonumber(tile, 16) }
      end
    end
  end
  f:close(); return cells
end

local tiles = readTiles()
local cells = readBat()
if tiles == nil or cells == nil then
  say("★ build/gfx/disclaimer.{tiles.bin,bat.tsv} 를 못 읽었다"); return
end

say(string.format("GFX 0.2.1 -- 타일 %d B · BAT %d 칸", #tiles, #cells))

local frame, injected = 0, 0
-- 지문이 **나타나는 순간**에만 넣으려고 든다.  한 번 넣으면 지문이 사라졌다
-- 다시 나타나기 전까지 안 넣는다.
local armed = false
local readbackBad, revertedNext = 0, 0
local lastWroteFrame = -1
local verdictSaid = false

local function signaturePresent()
  for index, want in ipairs(SIG) do
    if emu.read(SIG_AT + index - 1, VRAM) ~= want then return false end
  end
  return true
end

local function ourTilePresent()
  for index = 1, 8 do
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
    emu.write(at + 1, (cell[3] // 256) % 16, VRAM)
  end
end

emu.addEventCallback(function()
  frame = frame + 1

  -- ② 지난 프레임에 썼다면, 이번 프레임 **시작**에 아직 우리 것인지 본다
  if lastWroteFrame == frame - 1 then
    if not ourTilePresent() then
      revertedNext = revertedNext + 1
      if not verdictSaid then
        verdictSaid = true
        say("★판정 (a) -- 다음 프레임에 원본으로 돌아가 있다")
        say("   게임이 그 VRAM 을 계속 다시 올린다.  어셈블리도 매 프레임 써야 한다")
      end
    elseif not verdictSaid then
      verdictSaid = true
      say("★판정 (b) -- 우리 타일이 다음 프레임에도 남아 있다")
      say("   Lua 의 읽기/쓰기가 어긋난 것이다.  어셈블리는 한 번만 써도 된다")
    end
  end

  -- ★ 모서리에서만 넣는다 (0.2.0 은 여기서 495 번 넣고 **다음 페이지까지 덮었다**).
  --
  --   지문 자리($3C80)는 우리가 덮는 범위($2200-$38FF) 밖이라 넣고 나서도 계속
  --   남는다.  "이미 넣었나" 가드까지 안 걸리니 매 프레임 다시 넣었고, 화면이
  --   넘어간 뒤에도 계속 넣어 다음 화면을 뒤덮었다.
  --
  --   그래서 "지문이 **나타나는 순간**" 에만 넣는다.  사라졌다 다시 나타나야
  --   또 넣는다.  가드가 왜 안 걸리는지와 무관하게 한 번만 들어간다.
  local present = signaturePresent()
  if present and not armed then
    armed = true
    inject()
    injected = injected + 1
    lastWroteFrame = frame

    -- ① 쓴 직후 읽어 본다
    if not ourTilePresent() then
      readbackBad = readbackBad + 1
      if readbackBad == 1 then
        say("★쓴 직후 읽었는데 다르다 -- emu.write 가 안 먹거나 읽는 자리가 다르다")
      end
    end

    say(string.format("  f%d  넣었다 (%d 번째)", frame, injected))
  elseif not present then
    armed = false          -- 지문이 사라졌다.  다시 나타나면 그때 또 넣는다
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  say(string.format("끝 -- 넣은 횟수 %d", injected))
  say(string.format("  쓴 직후 읽기 불일치      %d", readbackBad))
  say(string.format("  다음 프레임에 되돌아감    %d", revertedNext))
  if injected == 0 then
    say("  한 번도 안 넣었다 -- 지문을 못 봤다")
  elseif revertedNext > 0 then
    say("  -> (a) 게임이 계속 다시 올린다.  매 프레임 쓰는 코드가 필요하다")
  elseif readbackBad > 0 then
    say("  -> (b) Lua 쓰기/읽기 문제.  어셈블리에서는 안 나타날 것이다")
  else
    say("  -> 한 번만 넣고 유지됐다.  가드가 제대로 걸렸다")
  end
end, emu.eventType.scriptEnded)
