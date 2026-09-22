-- SUB 0.4.67-blank -- 조각을 올리기 전에 블록을 비운다.  끝부분 잔상 제거
--
-- ── 증상과 근거 ──────────────────────────────────────────────────────────
--
-- 짧은 자막이 뜰 때 **끝부분에 앞 자막의 잔상**이 남는다.
--
-- 0.4.66 감시가 실패 사례에서 이렇게 찍었다:
--
--     VRAM변함 0     글리프는 멀쩡하다.  게임이 덮은 게 아니다
--     최소빈칸 31    슬롯도 넉넉하다 (19 필요)
--     줄초과 4       정상 사례와 같다.  안 늘었다
--
-- 즉 잔상은 게임이 만든 것이 아니라 **우리가 앞서 쓴 우리 글자**다.
--
-- 고정 base 라 조각들이 같은 자리를 쓴다:
--
--     조각 N     18 글자 -> 셀 0~17 에 글리프를 쓴다
--     조각 N+1    9 글자 -> 셀 0~8 만 새로 쓴다
--                셀 9~17 에는 조각 N 의 글자가 그대로 남는다   <- 잔상
--
-- allocator 판에서 안 보였던 이유도 같다.  거기서는 조각마다 **다른 base** 를
-- 골랐으므로 새 블록에 남은 것이 없었다.  고정 base 로 바꾸면서 생긴 부작용이다.
--
-- ── 고치는 법 ────────────────────────────────────────────────────────────
--
-- count_ok(engine off 118) 는 glyph_loop(off 149) 보다 **먼저** 온다.  그래서
-- count_ok 에서 블록 전체를 0 으로 밀어 두면, 곧이어 엔진이 자기 조각의 셀만
-- 다시 채우고 나머지는 빈 칸으로 남는다.  빈 칸 스프라이트는 안 보인다.
--
-- 0.4.64 가 같은 지점에서 base 를 박으므로 **그 뒤에** 등록해야 한다.
-- exec 콜백은 등록 순서대로 불리고 둘 다 명령 실행 전에 돈다.
--
-- 비용: 1216 word = 2432 회 쓰기, 조각마다 한 번.  매 프레임이 아니다.
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드 (안에서 0.4.64 를 부른다)
--     화면 아래: `0.4.67 비움 N`
--
-- 감시까지 같이 보려면 이 파일 대신 0.4.66 을 쓰고, 이 파일을 그 뒤에 얹으면
-- 된다 -- 다만 0.4.66 의 VRAM 지문은 비우기를 "변함" 으로 볼 것이므로 그때는
-- VRAM변함 숫자를 무시할 것.

dofile('C:/snatcher/lua/SUB/0.4.64-fixedbase.lua')

local MEM = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam
local CPU = emu.cpuType.pce

local ENGINE   = 0x5B80
local COUNT_OK = ENGINE + 118
local VRAM_LO, VRAM_HI = 144, 146
local NEED = 19 * 0x40                 -- 1216 word

local blanked = 0

emu.addMemoryCallback(function()
  local base = (emu.read(ENGINE + VRAM_LO, MEM) or 0) |
               ((emu.read(ENGINE + VRAM_HI, MEM) or 0) << 8)
  if base == 0 then return end
  -- 셀 하나가 0x40 word 다.  블록 전체를 민다.
  for w = base, base + NEED - 1 do
    local at = w * 2
    emu.write(at, 0, VRAM)
    emu.write(at + 1, 0, VRAM)
  end
  blanked = blanked + 1
end, emu.callbackType.exec, COUNT_OK, COUNT_OK, CPU, MEM)

emu.addEventCallback(function()
  emu.drawString(4, 74, string.format('0.4.67 비움 %d', blanked), 0x80FFC0, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.67-blank armed -- count_ok 에서 블록 1216 word 를 비운다')
emu.log('  짧은 조각이 앞 조각의 글자를 끝에 남기던 잔상을 없앤다')
emu.log('  glyph_loop(off 149) 보다 먼저 도는 지점이라 곧바로 새 글자가 채워진다')
