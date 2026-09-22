-- SUB 0.4.69-vdc -- 엔진이 도는 동안 VDC 레지스터가 하이재킹되는지 본다 (쓰기 0)
--
-- ── 가설 ─────────────────────────────────────────────────────────────────
--
-- 국장실에서 **화면이 덜덜 떨리고 타일맵 위쪽(천장의 인물)이 소환된다.**
-- 자막을 쓰는 순간에만 그렇다.  출하불가급 증상이다.
--
-- PC엔진 VDC 는 레지스터 선택 래치가 **하나**다.  접근이 두 단계다:
--
--     1  포트에 "몇 번 레지스터" 를 쓴다     <- 여기서 IRQ 가 끼면
--     2  데이터를 쓴다                       <- 데이터가 엉뚱한 레지스터로 간다
--
-- 스내처는 그림 창 때문에 **래스터 분할 IRQ** 를 쓴다.  화면을 그리는 도중
-- 인터럽트가 걸려 스크롤 레지스터를 바꾼다.  그런데 우리 엔진 631 B 에는
-- **SEI 가 0 개 · CLI 가 0 개**다 (실측).  인터럽트를 한 번도 안 막는다.
--
-- 그래서 우리 글리프 데이터가 세로 스크롤 레지스터(BYR)로 들어가면
-- 떨림과 타일맵 밀림이 정확히 그 모습이 된다.
--
-- ── 무엇을 잡나 ──────────────────────────────────────────────────────────
--
-- 엔진 실행 구간(count_ok ~ glyph_done)에 VDC 포트로 들어가는 쓰기를 모두 보고,
-- **우리가 쓸 리 없는 레지스터**에 값이 들어가면 찍는다.
--
--     우리가 쓰는 것   $00 MAWR · $02 VWR
--     위험한 것        $07 BXR · $08 BYR   <- 스크롤.  여기 찍히면 확정
--     그 밖            $05 CR · $06 RCR · $09 MWR · $13 DVSSR …
--
-- 한 줄이라도 BXR/BYR 이 찍히면 가설이 맞다.  하나도 안 찍히면 틀렸고,
-- 그때는 스크롤이 아니라 다른 경로를 봐야 한다.
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드 (안에서 0.4.64 를 부른다)
--     국장실에서 자막이 뜨는 장면을 지난다
--     dump/vdc_0_4_69_<시각>.tsv

dofile('C:/snatcher/lua/SUB/0.4.64-fixedbase.lua')

local MEM = emu.memType.pceMemory
local CPU = emu.cpuType.pce

local ENGINE     = 0x5B80
local COUNT_OK   = ENGINE + 118
local GLYPH_DONE = ENGINE + 289        -- 엔진 json 의 glyph_done
local VDC_LO, VDC_HI = 0x0000, 0x03FF

local NAME = {
  [0x00] = 'MAWR', [0x01] = 'MARR', [0x02] = 'VWR',  [0x05] = 'CR',
  [0x06] = 'RCR',  [0x07] = 'BXR',  [0x08] = 'BYR',  [0x09] = 'MWR',
  [0x0A] = 'HSR',  [0x0B] = 'HDR',  [0x0C] = 'VPR',  [0x0D] = 'VDW',
  [0x0E] = 'VCR',  [0x0F] = 'DCR',  [0x10] = 'SOUR', [0x11] = 'DESR',
  [0x12] = 'LENR', [0x13] = 'DVSSR',
}
local EXPECTED = { [0x00] = true, [0x02] = true }   -- 엔진이 정상적으로 쓰는 것

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/vdc_0_4_69_' .. stamp .. '.tsv'
local out = io.open(OUT, 'w')
if out then
  out:write('frame\treg\tname\tport\tvalue\tscroll\n')
  out:flush()
end

local frame, selReg = 0, 0
local inEngine = false
local hits, scrollHits = 0, 0
local seen = {}

emu.addMemoryCallback(function() inEngine = true end,
  emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)
emu.addMemoryCallback(function() inEngine = false end,
  emu.callbackType.exec, GLYPH_DONE, GLYPH_DONE, CPU, MEM)

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then
    selReg = value
    return
  end
  if not inEngine then return end
  if port ~= 2 and port ~= 3 then return end
  if EXPECTED[selReg] then return end

  local scroll = (selReg == 0x07 or selReg == 0x08)
  hits = hits + 1
  if scroll then scrollHits = scrollHits + 1 end
  if out then
    out:write(string.format('%d\t%02X\t%s\t%d\t%02X\t%s\n',
      frame, selReg, NAME[selReg] or '?', port, value, scroll and 'Y' or ''))
    out:flush()
  end
  local tag = string.format('%02X', selReg)
  if not seen[tag] then
    seen[tag] = true
    emu.log(string.format('SUB 0.4.69 %s 엔진 실행 중 $%02X(%s) 에 쓰기 · port%d = $%02X',
      scroll and '★★ 스크롤!' or '▲', selReg, NAME[selReg] or '?', port, value))
  end
end, emu.callbackType.write, VDC_LO, VDC_HI, CPU, MEM)

emu.addEventCallback(function()
  frame = frame + 1
  emu.drawString(4, 84, string.format('0.4.69 이상쓰기 %d  스크롤 %d', hits, scrollHits),
                 scrollHits > 0 and 0xFF4040 or (hits > 0 and 0xFFA000 or 0x60FF60),
                 0x000000)
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if out then out:close(); out = nil end
  emu.log(string.format('SUB 0.4.69 끝 -- 엔진 중 이상 레지스터 쓰기 %d회 (스크롤 %d회)',
                        hits, scrollHits))
  if scrollHits > 0 then
    emu.log('  ★★ 스크롤 레지스터가 엔진 실행 중에 쓰였다.  가설 확정.')
    emu.log('     고침: 빌더에서 VDC 접근을 PHP/SEI … PLP 로 감쌀 것')
  elseif hits == 0 then
    emu.log('  이상 없음.  VDC 하이재킹 가설은 틀렸다.  다른 경로를 봐야 한다.')
  end
  emu.log('  ' .. OUT)
end, emu.eventType.scriptEnded)

emu.log('SUB 0.4.69-vdc armed -- 엔진 실행 중 VDC 레지스터 감시 (쓰기 0)')
emu.log('  정상: $00 MAWR · $02 VWR 만 쓰여야 한다')
emu.log('  ★★ 가 뜨면 스크롤 레지스터가 오염된 것 = 떨림/타일맵 밀림의 원인')
emu.log('  ' .. OUT)
