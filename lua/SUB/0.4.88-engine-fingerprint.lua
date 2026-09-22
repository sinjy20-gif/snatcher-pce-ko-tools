-- SUB 0.4.88 -- 한 글자 엔진이 정말 $5B80 까지 갔는지 지문으로 가른다 (쓰기 0 B)
--
-- 왜 만들었나
-- ---------------------------------------------------------------------------
-- 0.4.87 을 두 번 돌렸는데 두 번 다 원본이 돌았다.  와이프가 1 칸이 아니라
-- 14/18/16 칸이었다.  그런데 로그에는 `AC install #1` 뿐이고 #2 가 없었다.
--
-- 원인 하나는 찾았다.  0.4.31 의 engineOk 가 표본 {0,1,2,50,630} 만 비교하는데
-- 두 엔진의 유일한 차이가 +$6D 라서 AC 에 원본이 남아 있어도 "일치" 로 읽혔다.
-- 그건 전량 비교로 고쳤다.  **그러나 그것이 전부인지는 아직 모른다.**
-- gate 가 AC $1F1F00 이 아닌 다른 곳에서 엔진을 복사한다면 전량 비교로도
-- 안 고쳐진다.  두 경우를 가르는 것은 바이트 하나다.
--
--     AC  $1F1F6D    우리가 올린 이미지의 판정 바이트   (ENGINE_AT + $6D)
--     CPU $5BED      gate 가 복사해 실제로 도는 코드    ($5B80  + $6D)
--
--     A9 01 EA   한 글자 엔진   (LDA #1 / NOP)
--     AD 38 5D   원본           (LDA record.cells)
--
-- 읽는 법
-- ---------------------------------------------------------------------------
--     AC=A9  CPU=A9    한 글자 엔진이 돈다.  와이프가 1 칸이어야 한다
--     AC=A9  CPU=AD    gate 의 복사 원본이 $1F1F00 이 아니다
--                      -> 그때는 그 주소를 찾는 것이 다음 일이다
--     AC=AD            우리 이미지가 덮였다.  덮인 프레임이 로그에 남는다
--
-- 쓰기는 하지 않는다.  읽기와 로그뿐이다.  자막 경로 자체는 0.4.87 과 같다.
--
-- 실행: Power Cycle 뒤 **이 파일 하나만** 로드한다.

SUB_CONTROLLER_ENGINE_PATH =
  'C:/snatcher/build/cutscene_subs/engine_ac_lua_frame_oneglyph.bin'
SUB_CONTROLLER_FORCE_ENGINE_UPLOAD = true
dofile('C:/snatcher/lua/SUB/0.4.82-fixedbase-fragment-wipe.lua')
SUB_CONTROLLER_ENGINE_PATH = nil
SUB_CONTROLLER_FORCE_ENGINE_UPLOAD = nil

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam

local ENGINE_AT, ENGINE_CPU, MARK = 0x1F1F00, 0x5B80, 0x6D
local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/engine_fp_0_4_88_' .. STAMP .. '.tsv'

local out = io.open(OUT, 'w')
if out then out:write('frame\tac\tcpu\tac_verdict\tcpu_verdict\n') end

local function triple(at, kind)
  local a = emu.read(at + 0, kind) or -1
  local b = emu.read(at + 1, kind) or -1
  local c = emu.read(at + 2, kind) or -1
  return string.format('%02X %02X %02X', a & 0xFF, b & 0xFF, c & 0xFF)
end

local function verdict(text)
  if text == 'A9 01 EA' then return 'oneglyph' end
  if text == 'AD 38 5D' then return 'original' end
  return 'other'
end

local frame, lastAc, lastCpu = 0, nil, nil

emu.addEventCallback(function()
  frame = frame + 1
  local ac = triple(ENGINE_AT + MARK, AC)
  local cpu = triple(ENGINE_CPU + MARK, MEM)
  if ac ~= lastAc or cpu ~= lastCpu then
    lastAc, lastCpu = ac, cpu
    local av, cv = verdict(ac), verdict(cpu)
    emu.log(string.format('SUB 0.4.88 FP %df · AC $%06X=%s (%s) · CPU $%04X=%s (%s)',
                          frame, ENGINE_AT + MARK, ac, av,
                          ENGINE_CPU + MARK, cpu, cv))
    if out then
      out:write(string.format('%d\t%s\t%s\t%s\t%s\n', frame, ac, cpu, av, cv))
      out:flush()
    end
  end
  emu.drawString(4, 44, string.format('0.4.88 FP AC:%s CPU:%s',
                 verdict(lastAc or ''), verdict(lastCpu or '')),
                 0x80FFD0, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.88-engine-fingerprint armed -- 읽기 전용 판정 바이트 감시')
emu.log('  AC $1F1F6D / CPU $5BED · A9=한 글자 · AD=원본')
emu.log('  로그: ' .. OUT)
