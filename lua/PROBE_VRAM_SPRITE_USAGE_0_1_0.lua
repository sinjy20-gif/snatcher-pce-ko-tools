-- PROBE_VRAM_SPRITE_USAGE 0.1.0 -- 게임이 안 쓰는 스프라이트 VRAM 구멍 찾기 (2026-08-26)
--
-- 왜 필요한가
-- -----------
-- 자막 글리프를 VRAM `$7900` 에 올렸더니 접수처에서 게임 아이콘이 그것을 그렸다.
-- 자리를 옮겼더니 **다른 장면**에서 같은 일이 났다.
--
--     PROBE_SUB_SATB 0.1.2 실측 (프레임 2130):
--       슬롯  0-15  y186 · w7900~7CC0 · 팔레트 F   <- 우리 자막
--       슬롯 20-23  y208~240 · w7900~7C00 · 팔레트 D   ★ 게임 아이콘
--
--     게임 아이콘 4 개가 우리 글리프 자리를 가리키고 있었다.  팔레트가 D 라
--     빨간 글자로 보였다.
--
-- 옮겨 보고 깨지면 또 옮기는 것으로는 안 끝난다.  장면마다 쓰는 자리가 다르다.
-- **한 판 돌면서 게임이 가리킨 VRAM 을 전부 모아** 구멍을 찾아야 한다.
--
-- 무엇을 모으나
-- -------------
-- SATB 64 슬롯의 패턴 주소를 매 프레임 훑어, 그 스프라이트가 덮는 워드 범위를
-- 표시한다.  스프라이트 한 장은 **64 워드**(16x16 4 플레인)다.
--
--     우리 것(팔레트 15)은 뺀다 -- 우리가 올린 것까지 세면 구멍이 안 남는다
--
-- 필요한 크기: 글리프 19 자 x $40 = **$4C0 연속 워드**
--
-- 쓰는 법
-- -------
--   1) Mesen 에 올린다 (자막 빌드든 원본이든 상관없다.  게임 것만 세므로)
--   2) **여러 장면을 돌아다닌다** -- 접수처 · 복도 · 국장실 · 밖 · 전투 등
--      많이 돌수록 확실해진다
--   3) Stop  ->  dump/vram_sprite_usage_<시각>.txt
--
-- 결과는 "한 번도 안 쓰인 연속 구간" 목록이다.  $4C0 이상인 것이 후보다.
-- 다만 **한 판 안 쓰였다고 영영 안전한 것은 아니다** -- 안 돌아본 장면이 있다.
-- 그래서 목록을 그대로 믿지 말고, 고른 뒤 그 자리로 한 판 더 돌려 확인할 것.

local VRAM = emu.memType.pceVideoRam

local SATB = 0x2000            -- VRAM **바이트** (Mesen 의 VRAM 은 바이트 주소)
local STRIDE, SPRITES = 8, 64
local SPRITE_WORDS = 64        -- 16x16 4 플레인 한 장
local WORDS = 0x8000           -- VRAM 워드 수
local NEED = 0x4C0             -- 글리프 19 자
local OUR_PALETTE = 15         -- 우리가 쓰는 팔레트.  이건 세지 않는다

local stamp = os.date("%Y%m%d_%H%M%S")
local PATH = "C:\\snatcher\\dump\\vram_sprite_usage_" .. stamp .. ".txt"

local used = {}                -- 워드 -> true
local frames, marked = 0, 0

emu.addEventCallback(function()
  frames = frames + 1
  if frames % 6 ~= 0 then return end        -- 6 프레임에 한 번이면 충분하다

  for i = 0, SPRITES - 1 do
    local at = SATB + i * STRIDE
    local function w(o)
      return (emu.read(at + o, VRAM) or 0) | ((emu.read(at + o + 1, VRAM) or 0) << 8)
    end
    local pattern, attr = w(4), w(6)
    if pattern ~= 0 and (attr & 0x0F) ~= OUR_PALETTE then
      local base = (pattern << 5) & 0xFFFF
      for k = 0, SPRITE_WORDS - 1 do
        local word = (base + k) & 0xFFFF
        if not used[word] then used[word] = true; marked = marked + 1 end
      end
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local lines = {}
  local function say(t) lines[#lines + 1] = t; emu.log(t) end

  say(string.format("VRAM 스프라이트 사용 조사 -- %d 프레임 · 쓰인 워드 %d / %d",
                    frames, marked, WORDS))
  say(string.format("찾는 크기: $%X 연속 워드 (글리프 19 자)", NEED))
  say("")
  say("-- 한 번도 안 쓰인 연속 구간 --")

  local holes, start = {}, nil
  for word = 0, WORDS - 1 do
    if used[word] then
      if start ~= nil then holes[#holes + 1] = { start, word - 1 }; start = nil end
    else
      if start == nil then start = word end
    end
  end
  if start ~= nil then holes[#holes + 1] = { start, WORDS - 1 } end

  table.sort(holes, function(a, b) return (a[2] - a[1]) > (b[2] - b[1]) end)
  local shown = 0
  for _, h in ipairs(holes) do
    local size = h[2] - h[1] + 1
    if size >= 64 and shown < 25 then
      shown = shown + 1
      say(string.format("   $%04X - $%04X   %5d 워드  %s",
                        h[1], h[2], size, size >= NEED and "★ 들어간다" or ""))
    end
  end
  if shown == 0 then say("   (없다 -- 더 돌아다녀야 하거나 VRAM 이 꽉 찼다)") end

  say("")
  say("주의: 한 판 안 쓰였다고 영영 안전한 것은 아니다.")
  say("      고른 자리로 한 판 더 돌려 확인할 것.")

  local file = io.open(PATH, "w")
  if file ~= nil then
    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    emu.log("-> " .. PATH)
  end
end, emu.eventType.scriptEnded)

emu.log("PROBE_VRAM_SPRITE_USAGE 0.1.0 -- 여러 장면을 돌아다닌 뒤 Stop")
emu.log("  게임 스프라이트가 가리킨 VRAM 을 모아 구멍을 찾는다")
emu.log("  -> " .. PATH)
