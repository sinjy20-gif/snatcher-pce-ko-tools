-- SUBTITLE_DRAW 0.2.0 -- 갈무리 글리프를 픽셀로 직접 찍는다
--
-- 왜 이렇게 하나
-- ---------------------------------------------------------------------------
-- `emu.drawString` 으로는 한글 자막을 못 그린다.  0.1.0~0.1.2 로 갈라서 확인했다:
--
--     좌표계        정상.  20 px 격자가 x=0~260 전부 보였고 게임 화면과 겹쳤다
--     drawString    **세로로 그린다.**  한 글자마다 아래로 내려간다
--     한글          **글리프가 없다.**  ASCII(JUNKER)만 찍히고 한글은 자리만 먹는다
--
-- 그래서 Mesen 폰트를 안 쓰고 우리 글리프를 `emu.drawPixel` 로 직접 찍는다.
-- 부수 효과가 더 크다: **실제 게임에서 보일 모습과 픽셀 단위로 같다.**
-- 자막 사양(크기·위치·줄바꿈·가독성)을 여기서 확정하면 그대로 엔진 사양이 된다.
--
-- 글리프 출처
-- ---------------------------------------------------------------------------
--     build/bios_font/galmuri_ks_2350.bin   16x16 · 32 B/글자 · KS 순서 (가=0)
--     build/bios_font/galmuri_ks_2350.tsv   글자 -> 오프셋
--
-- 16x16 을 쓰는 이유: 컷신 자막은 스프라이트로 그릴 예정이고 PCE 스프라이트가
-- 16x16 이다 (인계서 §2.2).  BIOS 본문이 쓰는 12x12 와는 별개다.
--
-- 외곽선
-- ---------------------------------------------------------------------------
-- 영상 위에 얹으므로 검은 1 px 외곽선이 없으면 밝은 배경에서 사라진다.
-- 글리프 비트를 8 방향으로 부풀려 먼저 깔고 그 위에 본체를 찍는다.
-- (인계서 §3 이 "외곽선을 오프라인에서 굽는다" 고 한 것과 같은 그림이다.)
--
-- 쓰는 법
-- ---------------------------------------------------------------------------
--   그냥 돌리면 시험 문장 몇 줄을 고정 위치에 그린다.  아래 LINES 를 고치면 된다.
--   프레임당 그리기 비용을 로그에 찍으므로 몇 자까지 감당되는지도 같이 나온다.

local ROOT      = "C:/snatcher/"
local PACK_PATH = ROOT .. "build/bios_font/galmuri_ks_2350.bin"
local MAP_PATH  = ROOT .. "build/bios_font/galmuri_ks_2350.tsv"

local GLYPH_W, GLYPH_H = 16, 16
local GLYPH_BYTES      = 32          -- 16 행 x 2 바이트

-- 자막 위치.  2026-08-20 소유자 지정: **그림 상자 안쪽 맨 아래**에 넣는다.
-- (상자 밑 검은 띠가 아니다.  거기는 인물 얼굴·입이 움직이는 자리다.)
--
-- 아래에 붙이는 것이므로 손잡이를 "바닥" 으로 잡는다 -- 줄 수가 바뀌어도 바닥이
-- 고정되고 위로 쌓인다.  눈금을 보고 SUB_BOTTOM 을 상자 안쪽 아래 테두리에 맞춘다.
-- 2026-08-20 소유자 지정 (스크린샷으로 확인): **큰 그림 상자 안쪽 맨 아래**.
-- 그 아래 초상화가 있는 영역이 아니다.  상자는 화면 위쪽 절반쯤을 차지한다.
local SUB_BOTTOM  = 140               -- 마지막 줄의 아래 끝 y.  눈금 보고 조절
local LINE_GAP    = 18                -- 줄 간격 (글리프 16 + 2)

-- 한 줄씩 넣기로 했으므로 기본은 한 줄이다.  두 줄이 필요한지 보려면
-- 아래 주석을 풀어 비교한다 (VRAM 슬롯 16 vs 32 가 여기서 갈린다).
local TEXTS = {
  "금일부로 JUNKER로 임명된 길리언 시드다.",
}

-- 바닥 기준으로 위로 쌓는다
local LINES = {}
for i, text in ipairs(TEXTS) do
  local fromBottom = #TEXTS - i        -- 마지막 줄이 0
  LINES[#LINES + 1] = {SUB_BOTTOM - 16 - fromBottom * LINE_GAP, text}
end
-- 글리프 실제 범위는 x=1..11 (2,350 자 전부 동일, 실측).  16 칸 중 왼쪽 1 · 오른쪽 4 가
-- 비어 있다.  그래서 자간을 16 으로 두면 4 px 이 그냥 벌어져 "가 나 다" 처럼 보인다.
local GLYPH_X0    = 1                 -- 글리프가 실제로 시작하는 칸
local GLYPH_WIDTH = 11                -- 실제 폭
-- 2026-08-20: LINE_X=2 로도 첫 글자가 통째로 잘렸다.  화면 왼쪽 경계가 x=0 이
-- 아니라는 뜻이다.  왼쪽에 눈금을 그려 실제 경계를 재고 나서 값을 정한다.
local LINE_X      = 24                -- 넉넉히 띄워 두고, 눈금으로 실제 경계를 본다
local COLOR_TEXT  = 0xFFFFFF
local COLOR_EDGE  = 0xFF000000        -- 불투명 검정 (Mesen 색은 AARRGGBB)
local HOLD        = 2                 -- 지속 프레임
local SHOW_RULER  = true              -- 왼쪽·위쪽 경계 눈금.  자리 잡으면 끈다
local ADVANCE     = GLYPH_WIDTH + 1   -- 글자 사이 1 px

-- ---------------------------------------------------------------------------

local pack, charOffset = nil, {}

local function loadPack()
  local f = io.open(PACK_PATH, "rb")
  if f == nil then return "글리프 팩을 못 연다: " .. PACK_PATH end
  pack = f:read("a"); f:close()

  f = io.open(MAP_PATH, "rb")
  if f == nil then return "배정표를 못 연다: " .. MAP_PATH end
  local text = f:read("a"); f:close()

  local n = 0
  for line in text:gmatch("[^\r\n]+") do
    -- ks_index<TAB>offset<TAB>char<TAB>unicode<TAB>sjis<TAB>filled
    local idx, off, ch = line:match("^(%d+)\t(%x+)\t([^\t]+)\t")
    if idx ~= nil and ch ~= nil and #ch > 0 then
      charOffset[ch] = tonumber(off, 16)
      n = n + 1
    end
  end
  if n == 0 then return "배정표에서 글자를 못 읽었다" end
  return nil, n
end

-- 한 글자의 16x16 비트를 [y][x] = true 로.  없으면 nil
local function bitmap(ch)
  local off = charOffset[ch]
  if off == nil then return nil end
  local rows = {}
  for y = 0, GLYPH_H - 1 do
    local hi = pack:byte(off + y * 2 + 1) or 0
    local lo = pack:byte(off + y * 2 + 2) or 0
    local value = hi * 256 + lo
    local row = {}
    for x = 0, GLYPH_W - 1 do
      row[x] = (value >> (15 - x) & 1) == 1
    end
    rows[y] = row
  end
  return rows
end

-- UTF-8 문자열을 글자 배열로
local function chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = c end
  return out
end

local drawn = 0

local function drawGlyph(rows, ox, oy)
  -- 외곽선 먼저: 켜진 비트의 8 이웃을 검게.  본체가 그 위를 덮는다
  for y = 0, GLYPH_H - 1 do
    for x = 0, GLYPH_W - 1 do
      if rows[y][x] then
        local px = ox + x - GLYPH_X0
        for dy = -1, 1 do
          for dx = -1, 1 do
            if not (dx == 0 and dy == 0) then
              emu.drawPixel(px + dx, oy + y + dy, COLOR_EDGE, HOLD)
              drawn = drawn + 1
            end
          end
        end
      end
    end
  end
  for y = 0, GLYPH_H - 1 do
    for x = 0, GLYPH_W - 1 do
      if rows[y][x] then
        emu.drawPixel(ox + x - GLYPH_X0, oy + y, COLOR_TEXT, HOLD)
        drawn = drawn + 1
      end
    end
  end
end

local cache = {}

-- 팩에는 한글 2,350 자만 있다.  ASCII 는 Mesen 폰트로 찍는다 -- 0.1.2 에서
-- ASCII(JUNKER)는 제대로 나오는 것이 확인됐다.  한 글자씩 넘겨야 세로로 안 흐른다.
local function drawLine(text, y)
  local x = LINE_X
  for _, ch in ipairs(chars(text)) do
    if ch == " " then
      x = x + math.floor(ADVANCE / 2)
    else
      local rows = cache[ch]
      if rows == nil then
        rows = bitmap(ch)
        cache[ch] = rows or false
      end
      if rows then
        drawGlyph(rows, x, y)
        x = x + ADVANCE
      else
        -- 팩에 없는 글자 (ASCII·기호).  Mesen 폰트로.  y 를 맞춰 살짝 내린다
        -- Mesen 폰트는 8 px 높이라 16x16 한글과 바닥을 맞추려면 더 내려야 한다.
        -- 갈무리 글리프는 y..y+15 를 쓰고 실제 획은 대략 y+2..y+13 이다.
        emu.drawString(x, y + 6, ch, COLOR_TEXT, COLOR_EDGE, HOLD)
        x = x + 8
      end
    end
  end
end

local frames, reported = 0, false

-- 오른쪽 끝 y 눈금.  자막을 어디 놓을지 눈으로 재기 위한 것이다.
-- 8 px 마다 짧은 눈금, 32 px 마다 긴 눈금 + 숫자.
local function ruler()
  for y = 0, 239, 8 do
    local long = (y % 32 == 0)
    local len = long and 10 or 4
    local color = long and 0xFF00FF00 or 0xFFFF8000
    for x = 256 - len, 255 do
      emu.drawPixel(x, y, color, HOLD)
    end
    if long then
      emu.drawString(232, y - 3, tostring(y), 0xFF00FF00, 0xC0000000, HOLD)
    end
  end
  -- 자막 영역의 위/아래를 가로선으로 표시.  상자 테두리와 맞춰 보기 위한 것
  local top = LINES[1][1]
  for x = 0, 255 do
    emu.drawPixel(x, top - 1, 0xFF0080FF, HOLD)
    emu.drawPixel(x, SUB_BOTTOM, 0xFF0080FF, HOLD)
  end
end

local function onFrame()
  drawn = 0
  if SHOW_RULER then ruler() end
  for _, item in ipairs(LINES) do
    drawLine(item[2], item[1])
  end
  frames = frames + 1
  if not reported and frames == 60 then
    reported = true
    emu.log(string.format("프레임당 drawPixel 약 %d 회", drawn))
  end
end

local err, count = loadPack()
if err ~= nil then
  emu.log("★ " .. err)
else
  emu.log("SUBTITLE_DRAW 0.2.0 -- 갈무리 글리프를 픽셀로 직접 찍는다")
  emu.log(string.format("  글리프 %d 자 적재 · 팩 %d B", count, #pack))
  local missing = {}
  for _, item in ipairs(LINES) do
    for _, ch in ipairs(chars(item[2])) do
      if ch ~= " " and charOffset[ch] == nil and ch:byte() > 127 then
        missing[#missing + 1] = ch
      end
    end
  end
  if #missing > 0 then
    emu.log("  ★ 팩에 없는 글자: " .. table.concat(missing, ""))
  end
  emu.addEventCallback(onFrame, emu.eventType.endFrame)
end
