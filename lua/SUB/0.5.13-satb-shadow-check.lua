-- SUB 0.5.13 -- BIOS 워크 RAM $2214/$2215 가 진짜 SATB shadow 인가 (쓰기 0 B)
--
-- 0.5.12 + 디스어셈으로 나온 것
-- ---------------------------------------------------------------------------
--     BIOS  $E40C  LDA #$13 / STA $F7 / STA $0000      ; DVSSR 선택
--           $E413  LDA $2214 / STA $0002               ; ★ RAM 에서 읽는다
--           $E419  LDA $2215 / STA $0003
--           -> 보고된 PC $E418 · $E41E  (보고 PC = 명령 시작 + 2)
--
--     게임  보고 $42EF · $42F1  ->  시작 $42ED · $42EF  (2 바이트 간격)
--           3 바이트 STA abs 는 못 들어간다.  ST1 #$00 / ST2 #$10 즉치다
--           매 프레임 $1000 을 쓴다 (6527 회 관측)
--
-- 즉 **게임 경로는 $2214/$2215 를 거치지 않는다.**  그 변수가 부팅 값($0700)에
-- 머물러 있으면 실제 DVSSR($1000)과 어긋난다.  그러면 shadow 로 쓸 수 없다.
--
-- 무엇을 재나
-- ---------------------------------------------------------------------------
--     매 프레임   $2214/$2215 를 읽어 조립한 값
--     동시에      DVSSR 포트 쓰기를 감시해 실제 최신 값
--     둘이 같은가
--
-- 판정
--     항상 같다        $2214/$2215 는 진짜 shadow 다.  헬퍼가 LDA 두 번이면 끝
--     다르다/고정      게임 경로가 RAM 을 안 거친다는 뜻.  다른 shadow 가 필요하다
--                      -> 그때는 게임 write site($42ED/$42EF)를 패치해
--                         즉치를 RAM 에도 남기게 하는 쪽으로 간다
--
-- ★ DVSSR 관측이 0 이면 판정하지 말 것.
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  장면을 몇 개 옮겨 다닌다.

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local SHADOW_LO, SHADOW_HI = 0x2214, 0x2215

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/satb_shadow_0_5_13_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tshadow\tdvssr\tmatch\n') end

local selReg, dvssr, seen = 0, -1, 0

emu.addMemoryCallback(function(address, value)
  local port = address & 3
  value = (value or 0) & 0xFF
  if port == 0 then selReg = value; return end
  if selReg ~= 0x13 then return end
  if dvssr < 0 then dvssr = 0 end
  if port == 2 then dvssr = (dvssr & 0xFF00) | value
  elseif port == 3 then dvssr = (dvssr & 0x00FF) | (value << 8); seen = seen + 1 end
end, emu.callbackType.write, 0x0000, 0x0003, CPU, MEM)

local function shadow()
  local lo = emu.read(SHADOW_LO, MEM) or 0
  local hi = emu.read(SHADOW_HI, MEM) or 0
  return (lo | (hi << 8)) & 0x7FFF
end

local frame, same, diff = 0, 0, 0
local lastPair = nil

emu.addEventCallback(function()
  frame = frame + 1
  if seen == 0 then
    emu.drawString(4, 84, '0.5.13 DVSSR 관측 0 -- 판정 불가', 0x4040FF, 0x000000)
    return
  end
  local sh = shadow()
  local dv = dvssr & 0x7FFF
  if sh == dv then same = same + 1 else diff = diff + 1 end

  local pair = string.format('%04X|%04X', sh, dv)
  if pair ~= lastPair then
    lastPair = pair
    emu.log(string.format('SUB 0.5.13 %df · $2214/15 = $%04X · 실제 DVSSR = $%04X · %s',
                          frame, sh, dv, (sh == dv) and '일치' or '★ 불일치'))
    if out then
      out:write(string.format('%d\t%04X\t%04X\t%d\n', frame, sh, dv,
                              (sh == dv) and 1 or 0))
      out:flush()
    end
  end

  emu.drawString(4, 84, string.format(
    '0.5.13 shadow $%04X / 실제 $%04X · 일치 %d · 불일치 %d',
    sh, dv, same, diff), (diff == 0) and 0x80FF80 or 0x4040FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.13-satb-shadow-check armed -- $2214/$2215 vs 실제 DVSSR')
emu.log('  ★ DVSSR 관측 0 이면 판정하지 말 것 · 장면을 옮겨 다닐 것')
emu.log('  로그: ' .. OUT)
