-- SUB 0.5.91 -- 로드 LBA 가 재생까지 이어지는지 증명한다 (충돌 키 보조판정 전제)
--
-- 무엇을 증명하려는가
-- ---------------------------------------------------------------------------
-- 자막 디스패처는 **재생 시점**에 호출된다.  그런데 게임이 sector 를 아는 것은
-- **로드 시점**이다.  그래서 색인에 LBA 를 넣는 것만으로는 충돌이 안 풀린다.
--
--     CD 로드 LBA 포착  ->  ADPCM RAM 영역과 연결  ->  재생 시 그 LBA 복원
--
-- 이 연결이 실제로 유지되는지 **먼저 재고** 구현에 들어간다.
--
-- 왜 필요한가
-- ---------------------------------------------------------------------------
-- 런타임 키는 6 B 다: end_addr u16 LE + rate u8 + ADPCM RAM 표본 3 B
-- (표본 위치는 end/4, end/2, 5*end/8 -- subtitle_pack.json 의 adpcm_index.key).
-- sector 가 안 들어간다.  그래서 서로 다른 음성 둘이 같은 키를 받는다.
--
--     00 30 0E 8E 03 8F   ADPCM_00492D / ADPCM_00524D   (자막 동일)
--     00 50 0E 80 08 80   ADPCM_0050DC / ADPCM_0056A1   (자막 다름)
--     00 98 0E 80 80 08   ADPCM_0047AF / ADPCM_00514A   (자막 다름)
--
-- 이 셋이 로드 LBA 로 갈리면, 충돌 키에만 LBA 보조판정을 붙여 해결된다.
-- 안 갈리면 다른 판별자를 찾아야 한다.
--
-- 어떻게 재나
-- ---------------------------------------------------------------------------
--     매 프레임  writeAddress 가 전진하면, 그 구간을 지금 sector 에 귀속시킨다
--                -> ADPCM RAM 구간 -> 출처 LBA 지도를 만든다
--     재생 시작  readAddress 가 어느 구간에 드는지 찾아 그 LBA 를 복원한다
--                그때 런타임 키 6 B 를 직접 계산해 충돌 키인지 본다
--
-- ★ 게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
-- ★ 판정은 재생마다 즉시 로그로 나온다.
--
-- 판정
--     충돌 키 하나가 서로 다른 LBA 로 두 번 나오면  -> 보조판정 성립.  구현 가능
--     같은 LBA 로만 나오면                          -> LBA 로도 못 가른다
--     연결이 끊기면(구간 못 찾음)                   -> 로드~재생 사이에 덮인다
--
-- 산출물  C:/snatcher/dump/adpcm_lba_link_0_5_91_<시각>.tsv

local ADP = emu.memType.pceAdpcmRam
local RAM_SIZE = 0x10000

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/adpcm_lba_link_0_5_91_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('seq\truntime_key\tcollide\tload_lba\tplay_sector\tread_addr\tend_addr\trate\t'
       .. 'seg_lo\tseg_hi\tlinked\tframe\n')

-- 충돌 키 3 쌍 (팩 빌더가 보고한 것)
local COLLIDE = {
  ['00300E8E038F'] = true,
  ['00500E800880'] = true,
  ['00980E808008'] = true,
}

local frame, seq = 0, 0
local segs = {}          -- { lo, hi, lba }  writeAddress 전진 구간 -> 출처 sector
local prevWrite, prevPlaying = nil, false

local function say(f, ...) emu.log(string.format(f, ...)) end

local function num(s, k)
  local v = s and s[k]
  return type(v) == 'number' and math.floor(v) or 0
end

local function st()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

local function playing(s)
  local v = s and (s['cdrom.adpcm.playing'] or s['cdrom.adpcm.isPlaying'])
  if type(v) == 'boolean' then return v end
  if type(v) == 'number' then return v ~= 0 end
  return nil
end

local function rb(a)
  local ok, v = pcall(emu.read, a % RAM_SIZE, ADP)
  return (ok and type(v) == 'number') and v or 0
end

-- 런타임 키 6 B = end_addr u16 LE + rate u8 + RAM 표본 3 B
local function runtimeKey(endAddr, rate)
  local s1 = rb(endAddr // 4)
  local s2 = rb(endAddr // 2)
  local s3 = rb((5 * endAddr) // 8)
  return string.format('%02X%02X%02X%02X%02X%02X',
    endAddr & 0xFF, (endAddr >> 8) & 0xFF, rate & 0xFF, s1, s2, s3)
end

-- readAddress 가 어느 적재 구간에 드는가
local function findSeg(addr)
  for i = #segs, 1, -1 do                 -- 최근 것부터
    local g = segs[i]
    if addr >= g.lo and addr < g.hi then return g end
  end
  return nil
end

emu.addEventCallback(function()
  frame = frame + 1
  local s = st()
  if not s then return end

  -- 1) 적재 추적 -- writeAddress 전진 구간을 지금 sector 에 귀속
  local w = num(s, 'cdrom.adpcm.writeAddress')
  local sector = num(s, 'cdrom.scsi.sector')
  if prevWrite and w ~= prevWrite then
    local step = (w - prevWrite) % RAM_SIZE
    if step > 0 and step < RAM_SIZE // 2 then
      segs[#segs + 1] = { lo = prevWrite, hi = prevWrite + step, lba = sector }
      if #segs > 400 then table.remove(segs, 1) end
    end
  end
  prevWrite = w

  -- 2) 재생 시작 -- 그때의 키와 출처 LBA 를 잇는다
  local on = playing(s)
  if on == nil then return end
  if on and not prevPlaying then
    seq = seq + 1
    local read = num(s, 'cdrom.adpcm.readAddress')
    local len  = num(s, 'cdrom.adpcm.adpcmLength')
    local rate = num(s, 'cdrom.adpcm.playbackRate')
    local endAddr = (read + len) % RAM_SIZE
    local key = runtimeKey(endAddr, rate)
    local g = findSeg(read)
    local linked = g and 'yes' or 'no'
    local col = COLLIDE[key] and 'YES' or ''
    out:write(string.format('%d\t%s\t%s\t%s\t%06X\t%04X\t%04X\t%02X\t%s\t%s\t%s\t%d\n',
      seq, key, col, g and string.format('%06X', g.lba) or '', sector,
      read, endAddr, rate,
      g and string.format('%04X', g.lo) or '', g and string.format('%04X', g.hi) or '',
      linked, frame))
    out:flush()
    if col == 'YES' then
      say('0.5.91 ★충돌키 %s · 로드LBA %s · 재생sector %06X · 연결 %s',
          key, g and string.format('%06X', g.lba) or '(못찾음)', sector, linked)
    elseif seq <= 12 then
      say('0.5.91 %s · 로드LBA %s · 연결 %s',
          key, g and string.format('%06X', g.lba) or '(못찾음)', linked)
    end
  end
  prevPlaying = on
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:close()
  say('0.5.91 끝 -- 재생 %d 건 관측 · 저장 %s', seq, PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.91-adpcm-lba-linkage armed -- 순수 관측 · 게임 무수정')
say('  로드 LBA 를 ADPCM RAM 구간에 붙여두고, 재생 때 되찾을 수 있는지 본다')
say('  충돌 키 3 개가 서로 다른 LBA 로 갈리면 보조판정이 성립한다')
say('  덤프 : ' .. PATH)
