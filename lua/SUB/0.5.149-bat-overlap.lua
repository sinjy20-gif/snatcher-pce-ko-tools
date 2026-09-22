-- SUB 0.5.149 -- 우리가 빌린 VRAM 을 배경이 실제로 쓰고 있는가
--
-- ★ 순수 관측.  아무것도 안 고친다.  게임 무수정.
--
-- 왜 재나 -- 소유자 증상
-- ---------------------------------------------------------------------------
-- "자막이 뜰 때마다 배경 그림이 깨진다" (책상 위 가로로 늘어선 블록).
-- 자막 줄이 아니라 **그림 안**이 깨진다.
--
-- 자막은 VRAM 을 음성 중에만 빌리고 끝나면 헬퍼가 1216 워드를 되돌린다.
-- 그 자리가 정말 비어 있으면 아무 일도 안 일어난다.  그런데 빌더 주석이 이미
-- 경고하고 있다:
--
--     "배경 타일은 $1100 에서 시작해 그림 크기만큼 위로 자라고,
--      국장실처럼 큰 그림에서는 $1A00 대까지 온다 (0.4.91 실측: 165/4096 엔트리)"
--
-- 빌린 자리를 배경이 쓰고 있으면, 자막이 떠 있는 **동안** 그림이 깨지는 것이
-- 설계상 당연한 결과다.  복원 문제가 아니다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
-- BAT(배경 타일맵)은 HuC6270 에서 VRAM $0000 부터다.  칸마다 16 bit 이고
-- 아래 12 bit 가 타일 번호다.  타일 n 이 쓰는 VRAM 워드는 [n*16, n*16+16).
--
--     우리 글리프 블록 = [vram_base_hi<<8, +19*64)      1216 워드
--     겹치는 BAT 칸을 센다
--
-- 무거워서 **음성이 바뀔 때 한 번만** 훑는다 (4096 칸 = 8192 읽기).
--
-- 판정
--     겹치는 칸 > 0   -> ★ 확정.  빌린 자리를 그림이 쓰고 있다.  자리를 옮겨야 한다
--                        로그의 '배경이 쓰는 최대 워드' 가 안전선을 알려준다
--     겹치는 칸 = 0   -> 자리는 결백.  깨짐은 다른 데서 온다
--
-- 산출물  C:/snatcher/dump/bat_overlap_0_5_149_<시각>.tsv

local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local ENGINE = 0x5B80
local A_VHI  = 0x5C7E        -- ★ 0.4.6.71 기준 (0.4.6.70 이하는 $5C72)
local A_COUNT = 0x5CFA
local STATE_ADDR = 0x7FDF
local BAT_WORDS = 4096       -- 0.4.91 실측이 4096 엔트리라고 했다
local GLYPH_WORDS = 19 * 64  -- 1216

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/bat_overlap_0_5_149_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tstate\tvram_hi\tblock_lo\tblock_hi\thits\tbg_max\tsamples\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM);  return (ok and type(v)=='number') and v or -1 end
local function rb(a) local ok,v = pcall(emu.read, a, VRAM); return (ok and type(v)=='number') and v or 0 end
local function rw(word) local at = word*2; return rb(at) | (rb(at+1) << 8) end

local function engineUp()
  return rd(ENGINE) == 0x53 and rd(ENGINE+1) == 0x55 and rd(ENGINE+2) == 0x42
end

-- BAT 를 훑어 우리 블록과 겹치는 칸을 센다.  배경이 쓰는 최대 워드도 같이 낸다
local function scanBat(lo, hi)
  local hits, bgMax, samples = 0, 0, {}
  for i = 0, BAT_WORDS - 1 do
    local tile = rw(i) & 0x0FFF
    local at = tile * 16
    if at > bgMax then bgMax = at end
    if at + 15 >= lo and at < hi then
      hits = hits + 1
      if #samples < 8 then samples[#samples+1] = ('%d@$%04X'):format(i, at) end
    end
  end
  return hits, bgMax, samples
end

local frame, lastVhi, scans = 0, -1, 0

emu.addEventCallback(function()
  frame = frame + 1
  if not engineUp() then return end
  local vhi   = rd(A_VHI)
  local count = rd(A_COUNT)
  if vhi <= 0 or count <= 0 then return end
  if vhi == lastVhi then return end        -- 음성이 바뀔 때만 훑는다
  lastVhi = vhi
  scans = scans + 1

  local lo = vhi << 8
  local hi = lo + GLYPH_WORDS
  local hits, bgMax, samples = scanBat(lo, hi)
  local state = rd(STATE_ADDR)
  local kind, note
  if hits > 0 then
    kind = 'OVERLAP'
    note = ('배경이 우리 블록을 %d 칸에서 쓰고 있다'):format(hits)
    say(('★OVERLAP f%-7d 글리프 $%04X-$%04X · 겹치는 BAT 칸 %d')
          :format(frame, lo, hi-1, hits))
    say(('        배경이 쓰는 최대 워드 $%04X   (안전선은 그 위)'):format(bgMax + 15))
    say(('        겹친 칸 %s'):format(table.concat(samples, ' ')))
  else
    kind = 'CLEAR'
    note = '겹치는 칸 없음'
    say(('  CLEAR f%-7d 글리프 $%04X-$%04X · 겹침 0 · 배경 최대 $%04X')
          :format(frame, lo, hi-1, bgMax + 15))
  end
  out:write(('%d\t%s\t%d\t%02X\t%04X\t%04X\t%d\t%04X\t%s\t%s\n'):format(
    frame, kind, state, vhi, lo, hi-1, hits, bgMax + 15,
    table.concat(samples, ' '), note))
  out:flush()
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(('# 훑은 음성 %d 개\n'):format(scans))
  out:close()
end, emu.eventType.scriptEnded)

say('SUB 0.5.149-bat-overlap armed -- 순수 관측')
say('  ★ 0.4.6.71 기준 주소.  음성이 바뀔 때만 BAT 4096 칸을 훑는다 (그때 한 번 버벅인다)')
say('  볼 것: ★OVERLAP 이 뜨는가 · 배경이 쓰는 최대 워드가 얼마인가')
say('  ' .. PATH)
