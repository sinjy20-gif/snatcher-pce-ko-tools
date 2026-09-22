-- GFX 0.2.2 -- 게임이 **다 올린 뒤**에 한 번만 넣는다
--
-- ⚠ 관측이 아니다.  VRAM 에 쓴다.
--
-- 0.2.0 / 0.2.1 에서 배운 것
-- --------------------------
-- ```
-- 0.2.0  매 프레임 넣었다      화면은 멀쩡했지만 495 번 넣었고 **다음 페이지까지 덮었다**
-- 0.2.1  한 번만 넣었다        판정 (b): 우리 타일이 다음 프레임에도 남는다
--                              ★그런데 화면이 깨졌다
-- ```
--
-- 왜 0.2.1 이 깨졌나 -- 너무 일찍 넣었다
-- --------------------------------------
-- 지문(타일 $1E4 = $09 F6 4A B5)은 게임이 **업로드를 시작할 때** 이미 나타난다.
-- 그 순간 넣으면 뒤이어 올라오는 원본 타일이 우리 것을 덮어써서 섞인다.
--
-- 0.2.0 이 멀쩡해 보였던 것은 매 프레임 다시 덮어 늘 이겼기 때문이다 -- 고쳐진
-- 것이 아니라 가려져 있었다.
--
-- 그래서 **멎을 때까지 기다린다**
-- ------------------------------
-- 글자 타일 구간의 앞머리를 매 프레임 훑어, 값이 SETTLE_FRAMES 프레임 동안
-- 안 바뀌면 업로드가 끝난 것으로 본다.  그때 한 번 넣는다.
--
-- 0.1.2 가 "f2896 이후 60 프레임 무변화" 를 봤으므로 창은 넉넉하다.
--
-- ⚠ 이 대기가 어셈블리 판의 설계도 정한다.  훅은 "화면이 뜰 때" 가 아니라
--   "업로드가 끝난 뒤" 에 걸려야 한다.
--
-- 쓰는 법 -- 스크립트 먼저 열고 부팅, 면책 화면까지.

local VRAM = emu.memType.pceVideoRam

local TILES = "C:/snatcher/build/gfx/disclaimer.tiles.bin"
local BATTSV = "C:/snatcher/build/gfx/disclaimer.bat.tsv"

local TILE_FIRST = 0x110
local TILE_BASE = TILE_FIRST * 32          -- $2200
local BAT_WIDTH = 64

local SIG_AT = 0x1E4 * 32
local SIG = { 0x09, 0xF6, 0x4A, 0xB5 }

local WATCH_AT, WATCH_BYTES = TILE_BASE, 512   -- 멎었는지 볼 구간
local SETTLE_FRAMES = 12                        -- 이만큼 안 바뀌면 끝난 것으로 본다

local function say(m) emu.log(m); print(m) end

local function readTiles()
  local f = io.open(TILES, "rb")
  if f == nil then return nil end
  local d = f:read("*all"); f:close(); return d
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

say(string.format("GFX 0.2.2 -- 타일 %d B · BAT %d 칸 · %d 프레임 무변화를 기다린다",
                  #tiles, #cells, SETTLE_FRAMES))

local frame, injected = 0, 0
local armed = false            -- 지문을 봤고 아직 안 넣었다
local done = false             -- 이번 등장에서 넣었다
local stable, lastDigest = 0, nil

local function signaturePresent()
  for index, want in ipairs(SIG) do
    if emu.read(SIG_AT + index - 1, VRAM) ~= want then return false end
  end
  return true
end

local function digest()
  local sum = 0
  for offset = 0, WATCH_BYTES - 1, 2 do
    sum = (sum * 31 + (emu.read(WATCH_AT + offset, VRAM) or 0)) % 0x7FFFFFFF
  end
  return sum
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
  local present = signaturePresent()

  if not present then
    if armed or done then
      say(string.format("  f%d  지문이 사라졌다 -- 다음 등장을 기다린다", frame))
    end
    armed, done, stable, lastDigest = false, false, 0, nil
    return
  end

  if done then return end

  if not armed then
    armed = true
    say(string.format("★f%d  지문을 봤다.  업로드가 멎기를 기다린다", frame))
  end

  local d = digest()
  if lastDigest ~= nil and d == lastDigest then
    stable = stable + 1
    if stable >= SETTLE_FRAMES then
      inject()
      injected = injected + 1
      done = true
      say(string.format("★f%d  멎었다 -- 넣었다 (%d 번째)", frame, injected))
    end
  else
    if lastDigest ~= nil and stable > 0 then
      say(string.format("  f%d  아직 올리는 중 (무변화 %d 에서 끊김)", frame, stable))
    end
    stable = 0
  end
  lastDigest = d
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  say(string.format("끝 -- 넣은 횟수 %d", injected))
  if injected == 0 then
    say("  한 번도 안 넣었다")
    say("  지문을 봤는데 안 넣었다면 SETTLE_FRAMES 만큼 멎은 적이 없다는 뜻이다")
  end
end, emu.eventType.scriptEnded)
