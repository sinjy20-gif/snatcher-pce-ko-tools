-- ★ HQ 1.3.0 -- **개입 실험**: VRAM 저장/복원이 장면 경계를 넘으면 깨지는가
--
-- ⚠ 읽기 전용이 아니다.  일부러 VRAM 을 건드린다.
--
-- 앞선 두 결과 (둘 다 0.5.10 · 트랙 3 자막 없는 판)
-- ------------------------------------------------
--     1.1.0  슬롯 $5B80-$5E1E 671 B 를 트랙 내내 점유 + 끝에 복원   ★멀쩡
--     1.2.0  VRAM $4B00 에 2 초마다 계속 쓰기                       ★멀쩡
--
-- 즉 **CPU 슬롯 점유도, VRAM 에 쓰는 것도 무죄**다.  저녁 내내 붙들었던
-- "스크립트 VM 스택을 뺏어서" 도, "잘못된 자리에 그려서" 도 아니었다.
--
-- 남은 것 -- 헬퍼의 저장/복원
-- --------------------------
-- 헬퍼는 자막 한 조각마다 `저장 -> 그리기 -> 복원` 을 한다.  그 사이클이
-- **장면 경계를 걸치면** 이렇게 된다:
--
--     접수처 화면을 백업으로 뜬다
--        ↓ 게임이 국장실로 화면을 갈아치운다
--     국장실 화면 위에 ★접수처 백업을 되쓴다
--
-- 이것이 0.5.17(자막 22 줄, 전환을 지나 계속) 과 0.5.18(11 줄, 전환 전에 소진)
-- 의 차이를 설명한다.  그리고 이미 겪은 병이다:
--
--     docs/handoff/SNATCHER_ENV_A_HANDOFF_2026-08-31.md
--       0.5.76  복원을 건너뜀            -> 여전히 깨짐
--       0.5.77  ★백업 내용만 최신화      -> 정상
--
-- 이 판이 하는 일
-- --------------
-- 자막 시스템 없이 **헬퍼의 리듬만** 흉내낸다:
--
--     t+0        VRAM BASE 부터 2,432 B 를 읽어 둔다        (저장)
--     t+HOLD     그 값을 그대로 되쓴다                       (복원)
--     PERIOD 마다 반복
--
-- 그리는 것은 하지 않는다 -- 1.2.0 이 그건 무죄로 판정했으니 변수를 줄인다.
--
-- 판정
--     국장실에서 깨진다  -> ★저장/복원이 원인 확정.  낡은 백업 문제
--     멀쩡하다           -> 셋 다 무죄.  전혀 다른 곳을 봐야 한다
--                            (스프라이트/SATB · 상주부 · 팔레트 ...)
--
-- 바꿔 볼 것
--     HOLD      복원까지의 지연.  길수록 "낡은 백업" 이 심해진다
--     STOP_SEC  33.8 로 두면 0.5.18 흉내 (여기서 멈추면 멀쩡해야 정상)
--
-- 쓰는 법
--     ★ build/patch/0.5.10 으로 Power Cycle -> 이 파일 하나만
--     트랙 3 을 자동 진행으로 국장실까지
--
-- 산출  dump/hq_1_3_0_vramrestore_<시각>.tsv

local VERSION = '1.3.0'
local MEM  = emu.memType.pceMemory
local VRAM = emu.memType.pceVideoRam

local BASE     = 0x4B00       -- word.  0.5.18 이 쓰던 자리
local WORDS    = 19 * 0x40    -- 1,216 word = 2,432 B
local PERIOD   = 120          -- 프레임.  2 초마다 한 사이클
local HOLD     = 90           -- 저장 -> 복원 지연 (1.5 초).  헬퍼보다 넉넉히 잡았다
local STOP_SEC = nil          -- 33.8 을 넣으면 0.5.18 흉내
local CD_RAW   = 0x26F9

local stamp = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/hq_' .. VERSION:gsub('%.', '_')
            .. '_vramrestore_' .. stamp .. '.tsv'
local out = assert(io.open(OUT, 'w'))
out:write('frame\telapsed\tevent\tcd_raw\tpc\n')

local function rb(at) return emu.read(at, MEM) or 0 end

local frame, rows = 0, 0
local startFrame = nil
local saved = nil          -- 뜬 백업
local restoreAt = nil      -- 되쓸 프레임
local cycles = 0

local function line(ev)
  local s = emu.getState() or {}
  local el = startFrame and string.format('%.2f', (frame - startFrame) / 60) or '-'
  out:write(string.format('%d\t%s\t%s\t%02X\t%04X\n',
    frame, el, ev, rb(CD_RAW), s['cpu.pc'] or 0))
  out:flush(); rows = rows + 1
end

local function save()
  local at = BASE * 2
  saved = {}
  for i = 0, WORDS * 2 - 1 do
    saved[i] = emu.read(at + i, VRAM) or 0
  end
  restoreAt = frame + HOLD
  cycles = cycles + 1
end

local function restore()
  if saved == nil then return end
  local at = BASE * 2
  for i = 0, WORDS * 2 - 1 do
    emu.write(at + i, saved[i], VRAM)
  end
  saved, restoreAt = nil, nil
end

emu.addEventCallback(function()
  frame = frame + 1
  local t = rb(CD_RAW) & 0x7F

  if t ~= 3 then
    if startFrame then
      if saved then restore() end
      line('TRACK_END'); startFrame = nil
    end
    return
  end

  if startFrame == nil then
    startFrame = frame
    line('TRACK3_START')
    emu.log(string.format(
      '★ 트랙 3 시작 frame=%d · $%04X %d word · %d 프레임마다 저장, %d 뒤 복원',
      frame, BASE, WORDS, PERIOD, HOLD))
  end

  local el = (frame - startFrame) / 60

  if restoreAt and frame >= restoreAt then
    restore()
    if cycles <= 8 or cycles % 5 == 0 then line('RESTORE#' .. cycles) end
  end

  if STOP_SEC and el > STOP_SEC then return end
  if saved == nil and (frame - startFrame) % PERIOD == 0 then
    save()
    if cycles <= 8 or cycles % 5 == 0 then line('SAVE#' .. cycles) end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write(string.format('# rows=%d frames=%d cycles=%d base=%04X hold=%d\n',
    rows, frame, cycles, BASE, HOLD))
  out:close()
  emu.log(string.format('★ 저장/복원 %d 사이클 -> %s', cycles, OUT))
end, emu.eventType.scriptEnded)

emu.log('HQ ' .. VERSION .. ' -- ★개입 실험.  헬퍼의 저장/복원 리듬만 흉내낸다')
emu.log('  ⚠ build/patch/0.5.10 으로 돌릴 것')
emu.log(string.format('  $%04X %d word · %d 프레임마다 저장 · %d 프레임 뒤 복원',
  BASE, WORDS, PERIOD, HOLD))
emu.log('  깨지면 -> 저장/복원이 원인.  멀쩡하면 -> 셋 다 무죄, 다른 곳')
emu.log('  -> ' .. OUT)
