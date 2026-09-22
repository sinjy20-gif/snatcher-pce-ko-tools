-- SUB 0.4.72-palette -- 자막 색이 왜 흰색이 아닌가.  팔레트를 강제로 밀어 본다
--
-- ── 근거 ─────────────────────────────────────────────────────────────────
--
-- 팔레트 뷰어 실측: 스프라이트 팔레트 15 의 **색 1($1F1)은 흰색**이다.
-- 우리 엔진의 stage 팔레트 루틴은 제대로 먹었다.  그런데 화면 글자는 청록이다.
--
--     -> 글리프가 색 1 을 안 쓰고 있다.
--
-- 우리 글리프는 2 플레인이라 픽셀값이 0~3 인데, 엔진이 초기화하는 것은
-- 색 1 과 색 2 뿐이다.  **색 3($1F3)은 한 번도 안 건드린다.**
-- 폰트가 같은 비트를 두 플레인에 모두 넣으면 픽셀값이 1 이 아니라 **3** 이 되고,
-- 그러면 게임이 남겨 둔 $1F3 색으로 그려진다.
--
-- ── 무엇을 하나 ──────────────────────────────────────────────────────────
--
-- 매 프레임 팔레트 15 의 색 1·2·3 을 직접 쓴다.  어느 색을 쓰든 글자가 흰색으로
-- 나와야 한다.
--
--     흰 글자가 나온다   -> 확정.  엔진의 팔레트 루틴에 색 3 초기화를 넣으면 끝
--     그대로 청록        -> 팔레트가 아니다.  다른 데를 봐야 한다
--
-- ⚠ 이 파일은 **쓴다** (VCE 팔레트 RAM).  진단용이지 출하용이 아니다.
--   색 3 을 흰색으로 밀면 게임의 다른 스프라이트가 그 팔레트를 쓸 때 같이 변한다.
--
-- ── 옵션 ─────────────────────────────────────────────────────────────────
--
--   SUB_PAL_C3   색 3 에 넣을 값.  기본 0x01FF(흰색)
--                0x0038 로 두면 초록 -- "정말 색 3 이 보이는가" 를 눈으로 확인
--
-- ── 쓰는 법 ──────────────────────────────────────────────────────────────
--
--     이 파일 하나만 로드 (안에서 0.4.71 을 부른다)

dofile('C:/snatcher/lua/SUB/0.4.71-pingpong.lua')

local VCE = emu.memType.pceVideoRam    -- 팔레트는 포트로 쓴다.  아래 참고
local MEM = emu.memType.pceMemory

-- VCE 레지스터 (CPU 주소)
local VCE_ADDR_LO, VCE_ADDR_HI = 0x0402, 0x0403
local VCE_DATA_LO, VCE_DATA_HI = 0x0404, 0x0405

local PAL15 = 0x01F0                   -- 스프라이트 팔레트 15 의 첫 칸

-- ★ 색 1·2·3 을 **서로 다른 색**으로 민다.  글자가 무슨 색으로 나오는지가
--   곧 "글리프가 몇 번 색을 쓰는가" 의 답이다.
--
--   PC엔진 색은 9비트 GGGRRRBBB 다.
local RED   = 0x0038                   -- G0 R7 B0
local GREEN = 0x01C0                   -- G7 R0 B0
local BLUE  = 0x0007                   -- G0 R0 B7

local C1 = rawget(_G, 'SUB_PAL_C1') or RED
local C2 = rawget(_G, 'SUB_PAL_C2') or GREEN
local C3 = rawget(_G, 'SUB_PAL_C3') or BLUE

local function setColor(index, value)
  emu.write(VCE_ADDR_LO, index & 0xFF, MEM)
  emu.write(VCE_ADDR_HI, (index >> 8) & 0x01, MEM)
  emu.write(VCE_DATA_LO, value & 0xFF, MEM)
  emu.write(VCE_DATA_HI, (value >> 8) & 0x01, MEM)
end

local frames = 0
emu.addEventCallback(function()
  frames = frames + 1
  setColor(PAL15 + 1, WHITE)           -- 색 1
  setColor(PAL15 + 2, BLACK)           -- 색 2
  setColor(PAL15 + 3, C3)              -- 색 3  ★ 엔진이 안 건드리던 것
  emu.drawString(4, 114, string.format('0.4.72 팔레트15 강제 %d프레임 (색3=$%03X)',
                 frames, C3), 0xFFFF80, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.4.72-palette armed -- 팔레트 15 의 색 1·2·3 을 매 프레임 강제로 쓴다')
emu.log(string.format('  색1=흰색 $%03X · 색2=검정 · 색3=$%03X', WHITE, C3))
emu.log('  글자가 흰색으로 바뀌면 원인은 "색 3 미초기화" 로 확정된다')
emu.log('  ⚠ 진단용이다.  게임의 다른 스프라이트도 이 팔레트를 쓰면 같이 변한다')
