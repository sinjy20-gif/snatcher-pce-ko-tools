-- SUB 0.5.136 -- 진짜 start LBA 를 관측한다.  역산값과 나란히 찍는다
--
-- ★ 순수 관측.  게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
--
-- 왜 재나
-- ---------------------------------------------------------------------------
-- 자막이 안 뜨는 음성은 무작위가 아니라 **키 가운데가 FFFF 인 것만**이다 (소유자 관측).
-- 전수 대조로 확인됐다:
--
--     정상  918 건   length 중앙 0x5FA3    길이 중앙  3.07 s   8.19초 초과   0 건
--     FFFF  173 건   length 중앙 0xFFBD    길이 중앙 11.23 s   8.19초 초과 163 건
--
-- ADPCM RAM 은 64 KB 다.  넘는 음성은 `adpcmLength` 가 포화하고, 색인 빌더가
-- 그 포화값으로 시작 위치를 되짚는다:
--
--     start_lba = sector - ceil(audio_length / 2048)     <- ★ 여기가 틀린다
--
-- 추정 오차는 중앙 12 섹터 · 최대 213 섹터.  173 중 164 가 틀렸다.
-- 그래서 디렉터리 이분 검색이 재생 중 진짜 LBA 를 못 만난다.
-- **키는 안 깨졌다** (양쪽 똑같이 FFFF 라 대조는 된다).  LBA 가 깨졌다.
--
-- 어떻게 재나 -- 되짚지 않는다
-- ---------------------------------------------------------------------------
--     매 프레임   writeAddress 가 전진하면 그 RAM 구간을 지금 sector 에 귀속시킨다
--     재생 시작   readAddress 가 어느 구간에 드는지 찾는다 -> 그게 **진짜 로드 LBA**
--
-- 같은 줄에 역산값도 찍으므로 오차가 바로 보인다.
--
-- 판정
--     SAT 행에서 true_lba 가 나오고 back_lba 와 다르다   -> 관측이 답이다.  색인 고치면 된다
--     true_lba 가 (못찾음)                               -> 로드~재생 사이에 덮인다.  다른 길 필요
--     정상 행에서 true_lba == back_lba                   -> 관측 방식 자체가 옳다는 검산
--
-- ★ 정상 음성에서 둘이 일치하는지를 **먼저** 보라.  거기서 어긋나면 관측을 못 믿는다.
--
-- 산출물  C:/snatcher/dump/true_start_lba_0_5_136_<시각>.tsv

local MAX_SEGS  = 4000        -- 구간 지도 상한.  넘으면 오래된 것부터 버린다
local SAT_MARK  = 0xFF00      -- 이 이상이면 포화로 본다

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/true_start_lba_0_5_136_' .. STAMP .. '.tsv'

local MEM = emu.memType.pceMemory
local K_FIN_LO, K_FIN_HI, K_RATE = 0x22A6, 0x22A7, 0x22AA

local out = io.open(PATH, 'w')
out:write('seq\tkey\tsat\tread\tlen\trate\tplay_sector'
       .. '\ttrue_lba\tback_lba\tdelta\tseg_lo\tseg_hi\tframe\n')

local function say(f, ...) local m = select('#',...)>0 and f:format(...) or f
  emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return ok and v or 0 end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or nil end

local segs, nseg = {}, 0
local frame, seq, playing, prevWrite = 0, 0, false, nil

local function findSeg(addr)
  for i = nseg, 1, -1 do            -- 최근 것부터.  같은 자리는 덮어써지므로
    local g = segs[i]
    if g and addr >= g.lo and addr < g.hi then return g end
  end
  return nil
end

local function onFrame()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local sector = num(s, 'cdrom.scsi.sector')
  local write  = num(s, 'cdrom.adpcm.writeAddress')
  local read   = num(s, 'cdrom.adpcm.readAddress')
  local len    = num(s, 'cdrom.adpcm.adpcmLength')
  local rate   = num(s, 'cdrom.adpcm.playbackRate')

  -- 1) 적재 추적 -- writeAddress 가 전진한 구간을 지금 sector 에 귀속시킨다
  if write and sector then
    if prevWrite and write ~= prevWrite then
      local step = (write - prevWrite) & 0xFFFF
      -- ⚠ 링버퍼다.  한 프레임에 32 KB 넘게 전진할 리 없다.  그러면 잡값이다
      if step > 0 and step < 0x8000 then
        nseg = nseg + 1
        segs[nseg] = { lo = prevWrite, hi = prevWrite + step, lba = sector }
        if nseg > MAX_SEGS then
          local keep, k = {}, 0
          for i = nseg - MAX_SEGS // 2, nseg do k = k + 1; keep[k] = segs[i] end
          segs, nseg = keep, k
        end
      end
    end
    prevWrite = write
  end

  -- 2) 재생 시작 순간
  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing and read and len then
    seq = seq + 1
    -- 키 앞 3 B 는 포트가 아니라 RAM 변수다 (BASELINE_2026-08-30 §측정 2)
    local fin = (rd(K_FIN_LO) | (rd(K_FIN_HI) << 8)) & 0xFFFF
    local rt  = rd(K_RATE) & 0xFF
    local sat = (len >= SAT_MARK) and 'SAT' or ''

    local g = findSeg(read)
    local back = sector and (sector - math.ceil(len / 2048)) or nil
    local delta = (g and back) and (g.lba - back) or nil

    out:write(('%d\t%04X%02X\t%s\t%04X\t%04X\t%02X\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n'):format(
      seq, fin, rt, sat, read, len, rate or 0,
      sector and ('%06X'):format(sector) or '',
      g and ('%06X'):format(g.lba) or '(못찾음)',
      back and ('%06X'):format(back) or '',
      delta and tostring(delta) or '',
      g and ('%04X'):format(g.lo) or '', g and ('%04X'):format(g.hi) or '', frame))
    out:flush()

    say('%s#%d  key=%04X%02X  read=%04X len=%04X  진짜LBA=%s  역산=%s  차이=%s',
        sat == 'SAT' and '★SAT ' or '     ', seq, fin, rt, read, len,
        g and ('%06X'):format(g.lba) or '(못찾음)',
        back and ('%06X'):format(back) or '?',
        delta and tostring(delta) or '?')
  end
  playing = isPlay
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
say('SUB 0.5.136-true-start-lba armed -- 순수 관측 · 게임 무수정')
say('  ★ 먼저 볼 것: 정상(SAT 아닌) 행에서 진짜LBA == 역산 인가.  거기서 검산된다')
say('  ★ 그 다음: SAT 행에서 진짜LBA 가 나오고 역산과 다른가')
say('  ' .. PATH)
