-- PROBE VRAM 빈자리 0.1.0 -- 0.2.4 가 쓴 $7B00 이 정말 빈 VRAM 이었나
--
-- 왜
-- ---------------------------------------------------------------------------
-- 0.2.4(패턴 업로드)가 화면을 깨뜨렸다.  원인 후보가 둘 남아 있다.
--
--   (1) $7B00 이 빈 자리가 아니었다        <- 이 프로브가 재는 것
--   (2) VBLANK 예산 초과                  <- frame_budget 으로는 못 잰다.
--                                            프레임 주기는 넘겨도 안 변한다
--
-- 0.2.4 는 이렇게 했다:
--     ST0 #0 / ST1 $00 / ST2 $7B    MAWR = $7B00  (워드 주소)
--     TIA pat -> $0002, 128 B       = 64 워드.  즉 $7B00-$7B3F 를 덮었다
--
-- 거기에 게임이 쓰던 패턴이나 BAT 가 있었으면 그걸 뭉갠 것이고, 화면이 깨진 이유가
-- 그것으로 끝난다.  IRQ 도 MAWR 도 아무 잘못이 없다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--   1. 전체 VRAM 을 1024 워드 블록으로 나눠 "0 이 아닌 바이트가 있나" 를 본다
--   2. 블록별로 **값이 바뀌는가** 도 센다.  게임이 살아 쓰는 자리는 바뀐다
--   3. $7B00-$7B3F 는 워드 단위로 따로 본다 (0.2.4 가 실제로 덮은 범위)
--
-- 살아 있는 자리라면 "안 비었다" 가 확정이고, 조용하면 후보 (2) 로 넘어간다.
--
-- 게임을 안 건드리는 수동 관측이다.
--
--     Script -> Settings -> Restrictions -> Allow I/O and OS

local VRAM = emu.memType.pceVideoRam

local WORDS       = 0x8000        -- 64 KB = 32768 워드
local BLOCK       = 0x400         -- 1024 워드 단위로 훑는다
local TARGET_LO   = 0x7B00        -- 0.2.4 가 덮은 범위
local TARGET_HI   = 0x7B3F
local EVERY       = 30            -- 표본 간격(프레임).  매 프레임 볼 필요가 없다

local stamp = "session"
if os ~= nil and os.date ~= nil then stamp = os.date("%Y%m%d_%H%M%S") end
local OUT = "C:/snatcher/dump/probe_vram_free_0_1_0_" .. stamp .. ".tsv"

local frame, samples = 0, 0
local nonzero, changed, prev = {}, {}, {}
local tgtNonzero, tgtChanged, tgtPrev = {}, {}, {}
local tgtMin, tgtMax = nil, nil

local function wordAt(w)
  local lo = emu.read(w * 2, VRAM)
  local hi = emu.read(w * 2 + 1, VRAM)
  if lo == nil or hi == nil then return nil end
  return hi * 256 + lo
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame % EVERY ~= 0 then return end
  samples = samples + 1

  -- 1) 블록 단위 -- 블록마다 32 워드만 표집한다 (전수는 너무 느리다)
  for b = 0, (WORDS / BLOCK) - 1 do
    local acc, base = 0, b * BLOCK
    for i = 0, 31 do
      local w = wordAt(base + i * (BLOCK / 32))
      if w ~= nil then acc = (acc + w) % 0x1000000 end
    end
    if acc ~= 0 then nonzero[b] = (nonzero[b] or 0) + 1 end
    if prev[b] ~= nil and prev[b] ~= acc then changed[b] = (changed[b] or 0) + 1 end
    prev[b] = acc
  end

  -- 2) 0.2.4 가 덮은 범위는 워드마다 본다
  for w = TARGET_LO, TARGET_HI do
    local v = wordAt(w)
    if v ~= nil then
      if v ~= 0 then
        tgtNonzero[w] = (tgtNonzero[w] or 0) + 1
        if tgtMin == nil or w < tgtMin then tgtMin = w end
        if tgtMax == nil or w > tgtMax then tgtMax = w end
      end
      if tgtPrev[w] ~= nil and tgtPrev[w] ~= v then
        tgtChanged[w] = (tgtChanged[w] or 0) + 1
      end
      tgtPrev[w] = v
    end
  end

  if samples % 20 == 0 then
    local nz, ch = 0, 0
    for w = TARGET_LO, TARGET_HI do
      if (tgtNonzero[w] or 0) > 0 then nz = nz + 1 end
      if (tgtChanged[w] or 0) > 0 then ch = ch + 1 end
    end
    emu.log(string.format("표본 %d  |  $7B00-$7B3F 중 0 아닌 워드 %d/64 · 변한 워드 %d/64",
      samples, nz, ch))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local f = io.open(OUT, "wb")
  if f == nil then emu.log("파일 열기 실패: " .. OUT); return end
  f:write("kind\taddr\tnonzero\tchanged\tsamples\n")
  f:write(string.format("SAMPLES\t\t\t\t%d\n", samples))
  for b = 0, (WORDS / BLOCK) - 1 do
    f:write(string.format("BLOCK\t%04X-%04X\t%d\t%d\t%d\n",
      b * BLOCK, b * BLOCK + BLOCK - 1, nonzero[b] or 0, changed[b] or 0, samples))
  end
  for w = TARGET_LO, TARGET_HI do
    f:write(string.format("TARGET\t%04X\t%d\t%d\t%d\n",
      w, tgtNonzero[w] or 0, tgtChanged[w] or 0, samples))
  end
  f:close()
  emu.log("PROBE VRAM 빈자리 0.1.0 -> " .. OUT)
end, emu.eventType.scriptEnded)

emu.log("PROBE VRAM 빈자리 0.1.0 시작 -- 음성 나오는 장면을 지나가면 된다")
