-- SUB 0.4.71-pingpong -- 조각마다 자리를 번갈아 쓴다.  자막 찢어짐 제거
--
-- ── 무엇을 고치나 ────────────────────────────────────────────────────────
--
-- 0.4.70 측정이 원인을 지목했다:
--
--     ★★ base $3B80 를 덮으려는데 지금 화면이 쓰고 있다
--        스프라이트 16 · BG타일 0
--
-- 조각 전환마다 15~18 개 스프라이트가 우리 블록을 가리키고 있었다.
-- **BG타일은 항상 0** -- 게임 것이 아니라 **이전 조각의 우리 자막**이다.
--
-- 고정 base 는 연속 조각이 같은 주소를 쓴다.  그래서 앞 조각이 화면에 떠 있는
-- 채로 그 위에 새 글리프를 덮고, VDC 가 그 자리를 읽는 중이라 그 프레임만
-- 찢어져 보인다.  다음 프레임엔 멀쩡해진다 -- 소유자 관측과 정확히 같다:
--
--     "글자가 새로 써지는 시점에 저게 살짝 나왔다가 바로 사라짐"
--
-- 자리를 둘로 나눠 번갈아 쓰면 **살아있는 자리를 절대 안 덮는다.**
--
-- ── 함께 확인된 것 ───────────────────────────────────────────────────────
--
--     게임이 우리 자리를 침범    없음 (0.4.65 · 90프레임 무변화)
--     게임이 그 자리를 다시 그림  전부 (0.4.70 · 512~4,736 word)
--         -> snapshot/restore 불필요.  복원이 만들던 UI 상자 잔상도 같이 사라진다
--
-- ── 이것으로 안 고쳐지는 것 ──────────────────────────────────────────────
--
-- 국장실 **화면 떨림**은 그대로다.  그건 다른 원인이다:
--
--     업로드가 34~69 스캔라인에 걸친다 (0.4.70 실측).  화면의 4분의 1이다.
--     TIA 는 인터럽트를 못 받으므로 래스터 분할 IRQ 가 밀린다.
--     -> 스크롤이 엉뚱한 줄에서 바뀌고, 밀린 정도가 매 프레임 달라 떨린다.
--
-- 그건 "한 프레임에 옮기는 양을 줄이는" 별도 수정이 필요하다 (엔진 쪽).
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     python tools/build_vram_key_bases.py --spans <spans2> --pairs
--     Power Cycle 후 이 파일 하나만 로드
--
-- 화면 아래: `0.4.71 핑퐁 N  A/B  미등록 M`

dofile('C:/snatcher/lua/SUB/0.4.64-fixedbase.lua')

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 118
local SELECTOR = ENGINE + 345
local VRAM_LO, VRAM_HI, PAT_LO, ATTR = 144, 146, 255, 260

local PAIRS_PATH = 'C:/snatcher/build/cutscene_subs/vram_key_bases_pairs.lua'
local PAIRS = assert(dofile(PAIRS_PATH), '핑퐁 표를 못 읽었다: ' .. PAIRS_PATH)

local n = 0
for _ in pairs(PAIRS) do n = n + 1 end
assert(n > 0, '핑퐁 표가 비었다.  --pairs 로 먼저 생성한다')

local function keyHex()
  local t = {}
  for i = 0, 5 do
    t[i + 1] = string.format('%02X', emu.read(SELECTOR + i, MEM) or 0)
  end
  return table.concat(t)
end

-- allocator 의 patchRenderer 와 같은 공식.
--   off 281 = 0x80(앞쪽우선) | 패턴상위<<4 | 팔레트   ($6463 이 AND #$70 / #$8F)
local function place(base)
  emu.write(ENGINE + VRAM_LO, base & 0xFF, MEM)
  emu.write(ENGINE + VRAM_HI, base >> 8, MEM)
  emu.write(ENGINE + PAT_LO, (base >> 5) & 0xFF, MEM)
  emu.write(ENGINE + ATTR, 0x80 | (((base >> 13) & 0x07) << 4) | 0x0F, MEM)
end

local flip, placed, unknown, lastKey = false, 0, 0, nil
local missing = {}

-- 0.4.64 가 같은 지점에서 단일 base 를 박는다.  **그 뒤에** 등록해 덮어쓴다.
emu.addMemoryCallback(function()
  local key = keyHex()
  local pair = PAIRS[key]
  if not pair then
    if not missing[key] then
      missing[key] = true
      unknown = unknown + 1
      emu.log(string.format('SUB 0.4.71 ▲ 표에 없는 키 %s -- 0.4.64 의 단일 자리를 쓴다', key))
    end
    return
  end

  -- 같은 음성 안에서만 번갈아도 충분하다.  음성이 바뀌면 앞 조각은 이미 사라진다.
  if key ~= lastKey then
    lastKey, flip = key, false
  else
    flip = not flip
  end

  local base = flip and pair[2] or pair[1]
  place(base)
  placed = placed + 1
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 104, string.format('0.4.71 핑퐁 %d  %s  미등록 %d',
                 placed, flip and 'B' or 'A', unknown),
                 unknown > 0 and 0xFFA000 or 0x80FFC0, 0x000000)
end, emu.eventType.endFrame)

emu.log(string.format('SUB 0.4.71-pingpong armed -- 키 %d개 · 조각마다 자리 교대', n))
emu.log('  표: ' .. PAIRS_PATH)
emu.log('  살아있는 자리를 안 덮으므로 자막 찢어짐이 사라져야 한다')
emu.log('  ⚠ 국장실 화면 떨림은 별개 원인(업로드가 34~69 스캔라인)이라 그대로다')
