-- GFX 0.3.1 -- **네이티브와 같은 형식**을 읽어 주입한다 (형식 검증판)
--
-- ⚠ 관측이 아니다.  VRAM 에 쓴다.
--
-- 왜 이걸 먼저 하나
-- -----------------
-- 다음 단계는 뱅크1 어셈블리 ~300 B 다.  거기서 형식이나 순서가 틀리면 실기에서
-- 화면이 깨진 채로 원인을 찾아야 한다.  그래서 **같은 페이로드를 같은 순서로**
-- 읽는 Lua 를 먼저 돌려 형식을 검증한다.  여기서 잘 나오면 어셈블리는 이 절차를
-- 그대로 옮기기만 하면 된다.
--
-- 0.3.0 과 다른 점
--     0.3.0   build/gfx/dedication.{tiles,bat}.tsv 를 직접 읽는다 (사람이 읽는 표)
--     0.3.1   ★build/gfx/gfx_screens.bin 을 읽는다 -- AC 에 올라갈 바로 그 바이트
--
-- 형식 (tools/pack_gfx_screens.py 와 같아야 한다.  전부 리틀엔디언)
-- ```
-- 헤더   +0  u8   active ($FF = 없음)
--        +1  u8   stable
--        +2  u8   sent
--        +3  u8   phase (0=대기, 2=전송, 3=완료)
--        +4  u16  화면 수
-- 화면 표는 +6부터 시작한다.
-- 화면 한 줄 (28 B)
--   +0   u16   지문 VRAM **워드** 주소
--   +2   16B   지문 기대값 (★원본 그림의 값이다.  우리 것을 넣으면 무한 재주입)
--   +18  u16   타일 수
--   +20  u16   BAT 칸 수
--   +22  u24   타일 블록 AC 주소
--   +25  u24   BAT 블록 AC 주소
-- 타일 34 B    u16 VRAM 워드 주소 + 32 B
-- BAT   4 B    u16 VRAM 워드 주소 + u16 값
-- ```
--
-- ★ 워드 주소다.  네이티브는 MAWR 에 그대로 넣으면 되고, Lua 는 바이트로 읽으므로
--   여기서만 x2 한다.  그 변환은 어셈블리에 없다.
--
-- 주입을 나눠 넣는 것도 네이티브와 같게 한다 (TILES_PER_FRAME).
-- 네이티브는 한 프레임에 다 넣으면 예산의 55 % 를 먹는다 (인계서 §24-2).
--
-- 쓰는 법 -- 헌사 화면 **전에** 올린다.

local VRAM = emu.memType.pceVideoRam
local PAYLOAD = "C:/snatcher/build/gfx/gfx_screens.bin"

local SETTLE_FRAMES = 12
local TILES_PER_FRAME = 8

local function say(m) emu.log(m); print(m) end

local f = io.open(PAYLOAD, "rb")
if f == nil then
  say("★ " .. PAYLOAD .. " 를 못 읽었다")
  say("   python tools/pack_gfx_screens.py --write")
  return
end
local blob = f:read("*all"); f:close()

local function u8(at) return blob:byte(at + 1) end
local function u16(at) return u8(at) + u8(at + 1) * 256 end
local function u24(at) return u16(at) + u8(at + 2) * 65536 end

local AC_BASE = 0x1A0000            -- pack 도구의 기본값.  블록 주소를 파일 오프셋으로 되돌린다
local function off(ac) return ac - AC_BASE end

local screens = {}
local n = u16(4)
for i = 0, n - 1 do
  local at = 6 + i * 28
  local sig = {}
  for k = 0, 15 do sig[#sig + 1] = u8(at + 2 + k) end
  screens[#screens + 1] = {
    sig_word = u16(at), sig = sig,
    tiles = u16(at + 18), cells = u16(at + 20),
    tiles_at = off(u24(at + 22)), bat_at = off(u24(at + 25)),
    stable = 0, done = false, phase = 0, sent = 0,
  }
end
say(("GFX 0.3.1 -- 화면 %d 개 · 페이로드 %d B"):format(n, #blob))
for i, s in ipairs(screens) do
  say(("  [%d] 지문 워드 $%04X · 타일 %d · BAT %d"):format(i, s.sig_word, s.tiles, s.cells))
end

local frame = 0

local function sig_matches(s)
  local base = s.sig_word * 2                  -- ★Lua 는 바이트 주소
  for k = 1, 16 do
    if emu.read(base + k - 1, VRAM) ~= s.sig[k] then return false end
  end
  return true
end

local function send_tiles(s, count)
  local first = s.sent
  local last = math.min(s.tiles, first + count) - 1
  for i = first, last do
    local at = s.tiles_at + i * 34
    local dst = u16(at) * 2
    for k = 0, 31 do
      emu.write(dst + k, u8(at + 2 + k), VRAM)
    end
  end
  s.sent = last + 1
  return s.sent >= s.tiles
end

local function send_bat(s)
  for i = 0, s.cells - 1 do
    local at = s.bat_at + i * 4
    local dst = u16(at) * 2
    local val = u16(at + 2)
    emu.write(dst, val % 256, VRAM)
    emu.write(dst + 1, (val // 256) % 16, VRAM)
  end
end

emu.addEventCallback(function()
  frame = frame + 1
  for i, s in ipairs(screens) do
    if s.phase == 2 then
      -- 주입 중: 몇 타일씩 옮긴다 (네이티브와 같은 이유로 나눈다)
      if send_tiles(s, TILES_PER_FRAME) then
        send_bat(s)
        s.phase, s.done = 3, true
        say(("  f%-7d ★[%d] 주입 완료 -- 타일 %d · BAT %d"):format(frame, i, s.tiles, s.cells))
      end
    else
      local ok = sig_matches(s)
      if not ok then
        if s.done then say(("  f%-7d [%d] 지문이 사라졌다 -- 다시 기다린다"):format(frame, i)) end
        s.stable, s.done, s.phase, s.sent = 0, false, 0, 0
      elseif not s.done then
        s.stable = s.stable + 1
        if s.stable == 1 then
          say(("  f%-7d [%d] ★지문 발견"):format(frame, i))
        end
        if s.stable >= SETTLE_FRAMES then
          s.phase, s.sent = 2, 0
          say(("  f%-7d [%d] 주입 시작 (%d 프레임 안정)"):format(frame, i, SETTLE_FRAMES))
        end
      end
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say("")
  for i, s in ipairs(screens) do
    say(("끝 [%d] %s"):format(i, s.done and "주입됨" or "★한 번도 안 넣었다"))
  end
end, emu.eventType.scriptEnded)

say("  헌사 화면 **전에** 올릴 것")
