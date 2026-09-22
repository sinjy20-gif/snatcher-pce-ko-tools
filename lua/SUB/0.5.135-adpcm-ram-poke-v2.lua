-- SUB 0.5.135 -- ADPCM RAM 표본을 BIOS 프로토콜로 읽고, 읽기 포인터를 되돌린다
--                                                                  ★개입판 v2
-- ⚠ 개입판이다.  ADPCM I/O 포트에 쓴다.  디스크는 안 건드린다.
--
-- 0.5.134 가 왜 무효였나
-- ---------------------------------------------------------------------------
-- `$1808/$1809` 만 쓰고 `$180D` 래치 비트를 안 건드렸다.  그래서 표본이 150/150
-- 전부 `FF`(오픈버스)였고, 재생이 안 깨진 것도 당연했다 -- 아무 일도 안 했으니까.
--
-- BIOS 자기 루틴 (BASELINE_2026-08-30 §측정 2)
-- ---------------------------------------------------------------------------
--     $F729  STX $1808 / STY $1809 / RTS         주소 설정
--     $F71E  LDA #$10 / TSB $180D
--            LDA #$10 / TRB $180D / RTS          읽기 포인터 래치
--     $F6FF  LDA #$08 / TSB $180D
--            LDA $180A                           더미 읽기
--            LDA #$05 / DEC A / BNE -            딜레이
--            LDA #$08 / TRB $180D
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- 1) key[0..2] 를 **RAM 에서** 읽는다 ($22A6/$22A7/$22AA).  포트 안 쓴다
-- 2) key[3..5] 를 $F6FF 방식($08 + 더미읽기)으로 세 번 읽는다
-- 3) 원래 읽기 포인터를 $22A6/$22A7 로 **되돌린다** ($F71E 방식, $10 set/clear)
-- 4) delta 가 흔들리는지 본다
--
-- 판정
--     표본이 FF 말고 실값으로 나온다        -> 프로토콜 맞다.  1 차 관문 통과
--     복구 뒤 delta 가 clean 과 같다        -> 안전.  지문 fallback 구현 가능
--     복구해도 delta 가 튄다                -> 파괴적.  다른 판별자를 찾아야 한다
--     RESTORE=false 일 때만 튄다            -> 복구가 실제로 일한다는 증거
--
-- ★ 귀로도 들으실 것.
--
-- 산출물  C:/snatcher/dump/adpcm_poke2_0_5_135_<시각>.tsv

local RESTORE   = true        -- false 로 두면 복구 없이 찌른다 (대조 실험)
local POKE_FROM = 30
local POKE_TO   = 60
local MAX_PLAYS = 12

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/adpcm_poke2_0_5_135_' .. STAMP .. '.tsv'

local MEM = emu.memType.pceMemory
local ADDR_LO, ADDR_HI, DATA, CTRL = 0x1808, 0x1809, 0x180A, 0x180D
local K_FIN_LO, K_FIN_HI, K_RATE = 0x22A6, 0x22A7, 0x22AA

local out = io.open(PATH, 'w')
out:write('play\tframe\toff\tphase\tread\tlen\trate\tdelta'
       .. '\tk0\tk1\tk2\ts0\ts1\ts2\trestored\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, MEM); return ok and v or -1 end
local function wr(a, v) pcall(emu.write, a, v, MEM) end
local function num(s, k) local v = s and s[k]; return type(v)=='number' and v or nil end

local function setAddr(a)
  wr(ADDR_LO, a & 0xFF)
  wr(ADDR_HI, (a >> 8) & 0xFF)
end

-- $F6FF 방식: $08 세우고 더미 읽고 실값 읽고 $08 내린다
local function readSample(a)
  setAddr(a)
  wr(CTRL, rd(CTRL) | 0x08)
  rd(DATA)                       -- 더미
  local v = rd(DATA)
  wr(CTRL, rd(CTRL) & ~0x08)
  return v
end

-- $F71E 방식: 원래 읽기 포인터를 되돌린다
local function restorePointer()
  setAddr(rd(K_FIN_LO) | (rd(K_FIN_HI) << 8))
  wr(CTRL, rd(CTRL) | 0x10)
  wr(CTRL, rd(CTRL) & ~0x10)
end

local frame, plays, playing, startFrame, prevRead = 0, 0, false, 0, nil

local function onFrame()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  local read = num(s, 'cdrom.adpcm.readAddress')
  local len  = num(s, 'cdrom.adpcm.adpcmLength')
  local rate = num(s, 'cdrom.adpcm.playbackRate')
  if read == nil then return end

  if isPlay and not playing then
    plays = plays + 1; prevRead = nil; startFrame = frame
    if plays <= MAX_PLAYS then say(('재생 %d 시작'):format(plays)) end
  end
  playing = isPlay
  if not isPlay or plays > MAX_PLAYS then return end

  local off = frame - startFrame
  local delta = prevRead and ((read - prevRead) & 0xFFFF) or -1
  prevRead = read

  -- key[0..2] 는 포트가 아니라 RAM 이다.  매 프레임 공짜로 읽는다
  local k0, k1, k2 = rd(K_FIN_LO), rd(K_FIN_HI), rd(K_RATE)

  local phase, s0, s1, s2, restored = 'clean', '', '', '', ''
  if off >= POKE_FROM and off < POKE_TO then
    phase = 'POKE'
    local fin = (k0 | (k1 << 8)) & 0xFFFF
    s0 = ('%02X'):format(readSample((fin >> 2) & 0xFFFF))
    s1 = ('%02X'):format(readSample((fin >> 1) & 0xFFFF))
    s2 = ('%02X'):format(readSample(((fin >> 3) * 5) & 0xFFFF))
    if RESTORE then restorePointer(); restored = 'Y' else restored = 'N' end
  end

  out:write(('%d\t%d\t%d\t%s\t%04X\t%04X\t%02X\t%d\t%02X\t%02X\t%02X\t%s\t%s\t%s\t%s\n')
    :format(plays, frame, off, phase, read, len or 0, rate or 0, delta,
            k0 & 0xFF, k1 & 0xFF, k2 & 0xFF, s0, s1, s2, restored))
  out:flush()
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
say('SUB 0.5.135-adpcm-ram-poke-v2 armed   RESTORE=' .. tostring(RESTORE))
say(('  찌르는 구간: 재생 시작 +%d ~ +%d 프레임'):format(POKE_FROM, POKE_TO))
say('  1차 관문: 표본이 FF 말고 실값으로 나오는가')
say('  2차 관문: 복구 뒤 delta 가 clean 과 같은가.  귀로도 들으실 것')
say('  ' .. PATH)
