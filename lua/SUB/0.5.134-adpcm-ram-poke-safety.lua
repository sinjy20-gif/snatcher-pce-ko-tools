-- SUB 0.5.134 -- 재생 중 ADPCM RAM 을 CPU 로 읽으면 재생이 깨지는가  ★개입판
--
-- ⚠ 개입판이다.  ADPCM I/O 포트에 쓴다.  디스크는 안 건드린다.
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- A2(ST_CONSUMED) 로 빠지는 음성에 자막이 안 뜬다.  고치려면 LBA 대신 6 B 지문으로
-- route 를 찾아야 하는데, 그 지문의 판별력은 전부 **ADPCM RAM 표본 3 B** 에서 온다.
--
--     레지스터만으로  (read+write+len+rate)  고유 665 / 1091   <- 못 쓴다
--     6 B 지문                                고유 1181 / 1219   <- 이것뿐이다
--
-- 그런데 Lua 는 ADPCM RAM 을 공짜로 훔쳐보지만 HuC6280 은 못 그런다.
-- `$1808/$1809` 로 주소를 잡고 `$180A` 를 읽어야 하는데, 그게 재생 중인
-- 읽기 포인터를 건드리면 소리가 튄다.
--
--     ★ 이게 안 되면 지문 방식 자체가 무너진다.  구현 전에 답이 나와야 한다.
--
-- 어떻게 재나 -- 같은 음성을 자기 대조군으로 쓴다
-- ---------------------------------------------------------------------------
-- 한 번의 재생 안에서 가운데 구간에만 찌른다.  같은 rate 로 도는 동안
-- `readAddress` 전진량은 프레임마다 일정해야 한다.
--
--     [시작 ~ +POKE_FROM)      안 찌름   <- 대조군
--     [+POKE_FROM ~ +POKE_TO)  찌름
--     [+POKE_TO ~ 끝)          안 찌름   <- 복귀 확인
--
-- 판정
--     delta 가 세 구간 내내 같다              -> 안전.  지문 fallback 구현 가능
--     찌른 구간에서 delta 가 튀거나 0 이 된다  -> 파괴적.  다른 판별자를 찾아야 한다
--     readAddress 가 표본 주소로 점프한다      -> 포인터를 직접 옮긴 것.  최악
--
-- ★ 귀로도 들으실 것.  숫자가 멀쩡해도 소리가 튀면 파괴적이다.
--
-- 산출물  C:/snatcher/dump/adpcm_poke_0_5_134_<시각>.tsv

local POKE_FROM = 30          -- 재생 시작 뒤 이 프레임부터 찌른다
local POKE_TO   = 60          -- 여기까지.  그 뒤엔 다시 안 찌른다
local MAX_PLAYS = 12          -- 이만큼 재생만 보고 멈춘다

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/adpcm_poke_0_5_134_' .. STAMP .. '.tsv'

local MEM  = emu.memType.pceMemory
local ADDR_LO, ADDR_HI, DATA = 0x1808, 0x1809, 0x180A

local out = io.open(PATH, 'w')
out:write('play\tframe\toff\tphase\tread\tlen\trate\tdelta\ts0\ts1\ts2\tjump\n')

local function say(m) emu.log(m); print(m) end

local function num(s, k)
  local v = s and s[k]
  if type(v) == 'number' then return v end
  return nil
end

-- 6280 이 할 일을 그대로 흉내낸다: 주소 래치 -> 데이터 포트 읽기
local function pokeRead(addr)
  pcall(emu.write, ADDR_LO, addr & 0xFF, MEM)
  pcall(emu.write, ADDR_HI, (addr >> 8) & 0xFF, MEM)
  local ok, v = pcall(emu.read, DATA, MEM)
  return ok and v or 0
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
    plays = plays + 1
    startFrame = frame
    prevRead = nil
    if plays <= MAX_PLAYS then say(('재생 %d 시작'):format(plays)) end
  end
  playing = isPlay

  if not isPlay or plays > MAX_PLAYS then return end

  local off = frame - startFrame
  local delta = prevRead and ((read - prevRead) & 0xFFFF) or -1
  prevRead = read

  local phase, s0, s1, s2, jump = 'clean', '', '', '', 0
  if off >= POKE_FROM and off < POKE_TO then
    phase = 'POKE'
    local endAddr = (read + (len or 0)) & 0xFFFF
    local a0 = (endAddr >> 2) & 0xFFFF
    local a1 = (endAddr >> 1) & 0xFFFF
    local a2 = ((endAddr >> 3) * 5) & 0xFFFF
    s0 = ('%02X'):format(pokeRead(a0))
    s1 = ('%02X'):format(pokeRead(a1))
    s2 = ('%02X'):format(pokeRead(a2))
    -- 찌른 직후 readAddress 가 표본 주소로 끌려갔는지 즉시 본다
    local ok2, s2s = pcall(emu.getState)
    local after = ok2 and num(s2s, 'cdrom.adpcm.readAddress') or read
    if after ~= read then jump = (after - read) & 0xFFFF end
  end

  out:write(('%d\t%d\t%d\t%s\t%04X\t%04X\t%02X\t%d\t%s\t%s\t%s\t%d\n')
    :format(plays, frame, off, phase, read, len or 0, rate or 0,
            delta, s0, s1, s2, jump))
  out:flush()
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
say('SUB 0.5.134-adpcm-ram-poke-safety armed')
say(('  찌르는 구간: 재생 시작 +%d ~ +%d 프레임'):format(POKE_FROM, POKE_TO))
say('  판정: delta 가 세 구간 내내 같으면 안전.  귀로도 들으실 것')
say('  ' .. PATH)
