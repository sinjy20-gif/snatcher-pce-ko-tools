-- ★ HQ 1.4.0 -- **개입 실험**: 스프라이트 슬롯을 뺏으면 국장실이 깨지는가
--
-- ⚠ 읽기 전용이 아니다.  일부러 SATB 를 건드린다.
--
-- 앞선 세 결과 (전부 0.5.10 · 트랙 3 자막 없는 판)
-- ----------------------------------------------
--     1.1.0  CPU 슬롯 $5B80-$5E1E 671 B 점유 + 복원      ★멀쩡
--     1.2.0  VRAM $4B00 에 계속 쓰기                     ★멀쩡
--     1.3.0  VRAM 저장 -> 복원 (낡은 백업)               ★멀쩡
--
-- 오늘 세운 가설이 전부 죽었다.  남은 것은 **우리가 게임과 공유하는 자원** 중
-- 아직 안 재본 것이다.
--
-- 왜 스프라이트인가
-- ----------------
-- 자막 렌더러는 글자 19 칸을 **스프라이트로** 민다.  PCE 스프라이트 슬롯은
-- **64 개뿐이고 게임과 공유**한다.  우리가 19 개를 쓰면 게임이 쓸 것이 19 개 준다.
--
--     ★ 국장님도 스프라이트다.  안 나온 이유가 이것일 수 있다.
--
-- 이 판이 하는 일
-- --------------
-- 자막 없이 **슬롯만 뺏는다.**  트랙 3 이 도는 동안 매 프레임 SATB 의 마지막
-- COUNT 칸을 우리 값으로 덮어쓴다.  글리프도, 헬퍼도, 슬롯 점유도 없다.
--
--     SATB      VRAM word $1000 (0.5.47 프로브 로그의 실측값).  다르면 고칠 것
--     한 칸     4 word = y · x · pattern · attr
--
-- 판정
--     국장님이 사라지고/진행이 막힌다  -> ★스프라이트 슬롯이 원인.  확정
--     멀쩡하다                          -> 이것도 무죄.  남은 것은 AC 포트 쪽
--                                          (cdda_check 가 채널 0 을 열고 나간다)
--
-- 바꿔 볼 것
--     FIRST     어느 칸부터 뺏는가 (렌더러가 실제로 쓰는 칸은 아직 미측정)
--     COUNT     몇 칸 (19 = 자막 한 줄)
--     OFFSCREEN true 면 화면 밖에 둔다.  false 면 눈에 보이게 그린다
--
-- 쓰는 법
--     ★ build/patch/0.5.10 으로 Power Cycle -> 이 파일 하나만
--     트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_1_4_0_sprite_<시각>.tsv

local VERSION = '1.4.0'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local SATB      = 0x1000      -- word.  스프라이트 속성표
local FIRST     = 45          -- 이 칸부터
local COUNT     = 19          -- 자막 한 줄이 쓰는 칸 수
local OFFSCREEN = true        -- 화면 밖에 두면 "자리만 뺏는" 순수 실험이 된다
local CD_RAW    = 0x26F9

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_sprite_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tcd_raw\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end
local function vw(word, value)                 -- VRAM 한 word 쓰기 (리틀엔디언)
  local at = word * 2
  emu.write(at, value & 0xFF, VRAM)
  emu.write(at + 1, (value >> 8) & 0xFF, VRAM)
end

local frame, rows = 0, 0
local startFrame = nil
local painted = 0

local function line(ev)
  local s = emu.getState() or {}
  local el = startFrame and string.format('%.2f', (frame - startFrame) / 60) or '-'
  out:write(string.format('%d\t%s\t%s\t%02X\t%04X\n',
    frame, el, ev, rb(CD_RAW), s['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end

local function grab()
  -- 스프라이트 한 칸 = y · x · pattern · attr (word 4 개)
  --   y = 64 + 화면y · x = 32 + 화면x  (PCE 규약)
  local y = OFFSCREEN and 0x0000 or (64 + 40)
  for i = 0, COUNT - 1 do
    local slot = (FIRST + i) % 64
    local w = SATB + slot * 4
    vw(w + 0, y)
    vw(w + 1, 32 + 8 * i)
    vw(w + 2, 0x0000)
    vw(w + 3, 0x0000)
  end
  painted = painted + 1
end

emu.addEventCallback(function()
  frame = frame + 1
  local t = rb(CD_RAW) & 0x7F
  if t ~= 3 then
    if startFrame then line('TRACK_END'); startFrame = nil end
    return
  end
  if startFrame == nil then
    startFrame = frame
    line('TRACK3_START')
    emu.log(string.format('★ 트랙 3 시작 frame=%d · SATB $%04X 의 %d~%d 칸을 매 프레임 뺏는다',
      frame, SATB, FIRST, FIRST + COUNT - 1))
  end
  grab()
  if painted % 600 == 1 then line('GRAB#' .. painted) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d grabs=%d satb=%04X first=%d count=%d\n',
    rows, frame, painted, SATB, FIRST, COUNT))
  out:close()
  emu.log(string.format('★ 슬롯 점유 %d 프레임 -> %s', painted, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- ★개입 실험.  스프라이트 슬롯만 뺏는다')
emu.log('  ⚠ build/patch/0.5.10 으로 돌릴 것')
emu.log(string.format('  SATB $%04X · %d 칸부터 %d 칸 · 화면밖=%s',
  SATB, FIRST, COUNT, tostring(OFFSCREEN)))
emu.log('  국장님 사라지거나 진행 막히면 -> 스프라이트가 원인')
emu.log('  -> ' .. OUT)
