-- SUB 0.5.138 -- 디스크 읽기 명령과 음성 재생을 한 줄에 놓는다
--
-- ★ 순수 관측.  게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
--
-- 0.5.137 에서 배운 것
-- ---------------------------------------------------------------------------
-- `$1800` 에 써지는 것은 `81` 뿐이라 CDB 가 아니었다.  대신 상태 키가 직접 있다:
--
--     cdrom.scsi.sector           읽기 위치
--     cdrom.scsi.sectorsToRead    ★ 지금 명령이 몇 섹터 남았나
--     cdrom.adpcm.dmaControl      CD -> ADPCM RAM 전송
--     cdrom.adpcm.dmaWriteCounter
--     cdrom.adpcm.addressPort     $1808/$1809 로 걸린 주소
--
-- 옵코드를 파싱할 이유가 없다.  **`sectorsToRead` 가 0 에서 서는 순간이 명령 시작**
-- 이고 그때 `sector` 가 진짜 시작 LBA 다.
--
-- 무엇을 보려는가
-- ---------------------------------------------------------------------------
-- 자막이 안 뜨는 것은 키 가운데가 FFFF 인 음성(8.19초·64KB 초과)뿐이다.
-- 데이터도 키도 LBA 도 다 맞는데 AC slot 이 A1(새 LBA 포착)을 못 받는다.
--
--     정상 음성  : 재생 직전에 읽기 명령이 있는가
--     FFFF 음성  : 그 명령이 **훨씬 앞**에 있는가 (선적재) 아니면 아예 없는가
--
-- 판정
--     FFFF 만 읽기가 훨씬 앞이다      -> 선적재 확정.  게이트를 재생 시점으로 옮겨야 한다
--     읽기가 정상과 같은 자리에 있다  -> 포착은 되는데 슬롯이 안 선다.  AC 슬롯 차례
--     FFFF 는 읽기가 여러 번 쪼개진다 -> 스트리밍.  첫 조각으로 arm 해야 한다
--
-- ★ 상한 없음.  값이 바뀐 프레임은 전부 적는다 (0.5.115/121 의 잘림 함정 회피)
--
-- 산출물  C:/snatcher/dump/scsi_read_0_5_138_<시각>.tsv

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/scsi_read_0_5_138_' .. STAMP .. '.tsv'

local MEM = emu.memType.pceMemory
local K_FIN_LO, K_FIN_HI, K_RATE = 0x22A6, 0x22A7, 0x22AA

local out = io.open(PATH, 'w')
out:write('frame\tkind\tsector\ttoRead\tdmaCtl\tdmaCnt\taddrPort'
       .. '\twrite\tread\tlen\tkey\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return ok and v or 0 end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or 0 end

local frame, playing = 0, false
local pSec, pToRead, pDmaCnt, pWrite = -1, -1, -1, -1
local lastReadStart, lastReadFrame = nil, nil

local function row(kind, s, note)
  out:write(('%d\t%s\t%06X\t%d\t%02X\t%d\t%04X\t%04X\t%04X\t%04X\t%s\t%s\n'):format(
    frame, kind,
    num(s,'cdrom.scsi.sector'), num(s,'cdrom.scsi.sectorsToRead'),
    num(s,'cdrom.adpcm.dmaControl') & 0xFF, num(s,'cdrom.adpcm.dmaWriteCounter'),
    num(s,'cdrom.adpcm.addressPort') & 0xFFFF,
    num(s,'cdrom.adpcm.writeAddress') & 0xFFFF,
    num(s,'cdrom.adpcm.readAddress') & 0xFFFF,
    num(s,'cdrom.adpcm.adpcmLength') & 0xFFFF,
    ('%04X%02X'):format((rd(K_FIN_LO) | (rd(K_FIN_HI) << 8)) & 0xFFFF, rd(K_RATE) & 0xFF),
    note or ''))
  out:flush()
end

local function onFrame()
  frame = frame + 1
  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local sec    = num(s, 'cdrom.scsi.sector')
  local toRead = num(s, 'cdrom.scsi.sectorsToRead')
  local dmaCnt = num(s, 'cdrom.adpcm.dmaWriteCounter')
  local write  = num(s, 'cdrom.adpcm.writeAddress')

  -- 읽기 명령 시작 = sectorsToRead 가 0 에서 섰다
  if pToRead == 0 and toRead > 0 then
    lastReadStart, lastReadFrame = sec, frame
    row('READ_START', s, ('%d 섹터 요청'):format(toRead))
    say(('  READ  f%-6d LBA=%06X  %d 섹터'):format(frame, sec, toRead))
  elseif pToRead > 0 and toRead == 0 then
    row('READ_END', s, ('LBA %06X 에서 시작했던 것'):format(lastReadStart or 0))
  elseif toRead ~= pToRead or sec ~= pSec or dmaCnt ~= pDmaCnt or write ~= pWrite then
    row('MOVE', s)
  end
  pSec, pToRead, pDmaCnt, pWrite = sec, toRead, dmaCnt, write

  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing then
    local len = num(s, 'cdrom.adpcm.adpcmLength')
    local sat = (len >= 0xFF00) and '★SAT' or ''
    local gap = lastReadFrame and (frame - lastReadFrame) or -1
    row('PLAY', s, ('%s 마지막읽기 LBA=%s 그로부터 %d 프레임 전'):format(
      sat, lastReadStart and ('%06X'):format(lastReadStart) or '(없음)', gap))
    say(('%s PLAY f%-6d len=%04X  마지막읽기 LBA=%s (%d 프레임 전)'):format(
      sat == '' and '     ' or sat, frame, len,
      lastReadStart and ('%06X'):format(lastReadStart) or '(없음)', gap))
  end
  playing = isPlay
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.138-scsi-read-trace armed -- 순수 관측 · 게임 무수정')
say('  ★ 볼 것: FFFF 음성만 "마지막읽기" 가 훨씬 전인가')
say('  ' .. PATH)
