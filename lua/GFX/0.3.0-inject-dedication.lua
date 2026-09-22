-- GFX 0.3.0 -- 헌사 화면을 한국어 그림으로 갈아끼운다
--
-- ⚠ 관측이 아니다.  VRAM 에 쓴다.
--
-- 0.2.2(면책 화면)와 무엇이 다른가
-- --------------------------------
-- ```
-- 타일 구간   $110-$1F5  연속 덩어리      -> ★$111~ 중 **우리가 채운 136 개만**
-- BAT         안 건드린다                 -> ★15 칸을 고친다
-- 지문        타일 $1E4 = 09 F6 4A B5     -> 타일 $16A = 80 00 40 00 ...
-- ```
--
-- ★왜 희소하게 쓰나 -- 연속으로 쓰면 그 사이의 **안 쓰는 타일까지** 굽는 시점의
--   덤프 내용으로 덮는다.  실기 상태가 덤프와 다르면 그게 사고가 된다.
--   우리가 실제로 그린 타일만 쓴다.
--
-- ★왜 BAT 을 고치나 -- 원본 일본어가 「、」「』」 옆을 비워 둬서 그 칸이 배경
--   타일이다.  배경 타일은 화면 전체와 공유라 거기에 우리 잉크를 놓으면 배경이
--   같이 바뀐다.  그래서 그런 칸(과 두 칸이 공유하던 타일)에는 **안 쓰는 타일**을
--   하나씩 내주고 BAT 만 그쪽으로 돌린다.  실측: 그렇게 안 하면 2줄에서 52 px,
--   3줄에서 107 px 가 잘린다.
--
--   ⚠ 이건 면책 화면에 없던 동작이다.  게임이 나중에 BAT 을 다시 쓰면 우리가
--     돌린 15 칸이 원복되고 그 자리 글자만 사라진다 (화면이 깨지지는 않는다).
--     실기에서 이걸 같이 볼 것.
--
-- 언제 넣나 -- 0.2.2 에서 배운 그대로
-- -----------------------------------
-- 지문은 게임이 **업로드를 시작할 때** 이미 나타난다.  그 순간 넣으면 뒤이어
-- 올라오는 원본이 우리 것을 덮어 섞인다 (0.2.1 이 그렇게 깨졌다).  그래서
-- 글자 타일 구간이 SETTLE_FRAMES 프레임 동안 안 바뀔 때까지 기다렸다 한 번 넣는다.
--
-- ★0.2.2 는 앞 512 B 만 봤다.  헌사 화면은 그림을 한 번에 올리므로 그것으로도
--   되겠지만, 구간 전체를 보는 편이 안전하고 비용도 비슷하다 (4 바이트마다).
--
-- 쓰는 법 -- 스크립트 먼저 열고 부팅, 헌사 화면까지.

local VRAM = emu.memType.pceVideoRam

local TILETSV = "C:/snatcher/build/gfx/dedication.tiles.tsv"
local BATTSV  = "C:/snatcher/build/gfx/dedication.bat.tsv"

local BAT_WIDTH = 64
local TILE_FIRST, TILE_LAST = 0x111, 0x18C     -- 원본 글자 타일 구간 (감시용)
local WATCH_AT = TILE_FIRST * 32
local WATCH_BYTES = (TILE_LAST - TILE_FIRST + 1) * 32
local WATCH_STEP = 4
local SETTLE_FRAMES = 12

local SIG_AT = 0x16A * 32                      -- VRAM $2D40
local SIG = { 0x80, 0x00, 0x40, 0x00, 0x20, 0x00, 0x10, 0x00 }

local function say(m) emu.log(m); print(m) end

local function readTiles()
  local f = io.open(TILETSV, "r")
  if f == nil then return nil end
  local out, first = {}, true
  for line in f:lines() do
    if first then first = false else
      local tile, hex = line:match("^(%x+)\t(%x+)")
      if tile ~= nil then
        local bytes = {}
        for i = 1, #hex, 2 do
          bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16)
        end
        out[#out + 1] = { tonumber(tile, 16), bytes }
      end
    end
  end
  f:close(); return out
end

local function readBat()
  local f = io.open(BATTSV, "r")
  if f == nil then return nil end
  local out, first = {}, true
  for line in f:lines() do
    if first then first = false else
      local row, col, tile = line:match("^(%d+)\t(%d+)\t(%x+)")
      if row ~= nil then
        out[#out + 1] = { tonumber(row), tonumber(col), tonumber(tile, 16) }
      end
    end
  end
  f:close(); return out
end

local tiles = readTiles()
local cells = readBat()
if tiles == nil or cells == nil then
  say("★ build/gfx/dedication.{tiles.tsv,bat.tsv} 를 못 읽었다")
  say("   python tools/bake_gfx_dedication.py --text build/gfx/dedication.txt")
  return
end

say(string.format(
  "GFX 0.3.0 헌사 -- 타일 %d 개 · BAT %d 칸 · %d 프레임 무변화를 기다린다",
  #tiles, #cells, SETTLE_FRAMES))

local frame, injected = 0, 0
local armed, done = false, false
local stable, lastDigest = 0, nil

local function signaturePresent()
  for index, want in ipairs(SIG) do
    if emu.read(SIG_AT + index - 1, VRAM) ~= want then return false end
  end
  return true
end

local function digest()
  local sum = 0
  for offset = 0, WATCH_BYTES - 1, WATCH_STEP do
    sum = (sum * 31 + (emu.read(WATCH_AT + offset, VRAM) or 0)) % 0x7FFFFFFF
  end
  return sum
end

local function inject()
  for _, entry in ipairs(tiles) do
    local base = entry[1] * 32
    for i, b in ipairs(entry[2]) do
      emu.write(base + i - 1, b, VRAM)
    end
  end
  for _, cell in ipairs(cells) do
    local at = (cell[1] * BAT_WIDTH + cell[2]) * 2
    emu.write(at, cell[3] % 256, VRAM)
    emu.write(at + 1, (cell[3] // 256) % 16, VRAM)
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  local present = signaturePresent()

  if not present then
    if armed and not done then
      say(string.format("  f%d  지문이 사라졌다 (아직 안 넣었다) -- 다시 기다린다", frame))
    end
    armed, done, stable, lastDigest = false, false, 0, nil
    return
  end

  if done then return end

  if not armed then
    armed, stable, lastDigest = true, 0, nil
    say(string.format("  f%d  ★지문 발견 -- 업로드가 멎기를 기다린다", frame))
  end

  local d = digest()
  if lastDigest ~= nil and d == lastDigest then
    stable = stable + 1
  else
    stable = 0
  end
  lastDigest = d

  if stable >= SETTLE_FRAMES then
    inject()
    injected = injected + 1
    done = true
    say(string.format("  f%d  ★넣었다 (%d 번째) -- 타일 %d · BAT %d",
                      frame, injected, #tiles, #cells))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  say(string.format("끝 -- 전체 %d 프레임 · 주입 %d 회", frame, injected))
  if injected == 0 then
    say("  ★한 번도 안 넣었다.  지문($16A = 80 00 40 00 ...)을 못 봤거나")
    say("    화면까지 안 갔다.  헌사 화면 전에 스크립트를 열었는지 확인할 것")
  end
end, emu.eventType.scriptEnded)

say("  헌사 화면 **전에** 올려둘 것.  화면이 뜨고 그림이 멎으면 자동으로 넣는다")
