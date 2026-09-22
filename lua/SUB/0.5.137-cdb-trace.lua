-- SUB 0.5.137 -- 게임이 디스크에 실제로 내리는 명령(CDB)을 뜬다
--
-- ★ 순수 관측.  게임을 한 바이트도 안 고친다.  화면에 아무것도 안 그린다.
--
-- 왜 만드나
-- ---------------------------------------------------------------------------
-- 지금까지는 전부 **산출물에서 추론**했다.  키도 LBA 도 표도 다 멀쩡한데
-- 자막이 안 뜨니, 이제 "게임이 이 음성을 무엇으로 재생하는가" 를 직접 봐야 한다.
--
-- 0.4.6.65 인계서가 게이트를 이렇게 적었다:
--     "새 $003123 **CDB**/LBA 가 native slot 에 A1 로 들어오지 않는다"
-- 즉 게이트가 잡는 것은 **게임이 SCSI 데이터 포트에 쓰는 명령블록**이다.
--
-- 무엇을 적나
-- ---------------------------------------------------------------------------
--     CDB   $1800 에 연속으로 써 넣는 바이트를 그대로 모은다 (해독 안 함)
--           2 프레임 이상 조용하면 한 덩어리로 끊는다
--     PLAY  ADPCM 재생이 시작된 프레임.  직전 CDB 들과 나란히 놓는다
--
-- ★ 옵코드를 추측하지 않는다.  원바이트를 적고 눈으로 본 뒤 해독한다.
--   (상한을 두면 "잘렸다" 를 반드시 남긴다 -- 0.5.115/0.5.121 에서 두 번 밟았다)
--
-- 보는 법
--     PLAY 행 바로 위의 CDB 가 그 음성을 실어온 명령이다
--     정상 음성과 FFFF 음성에서 그 관계가 **다른가** 를 본다
--       다르다  -> 왜 A1 이 안 오는지 거기 답이 있다
--       같다    -> CDB 는 오는데 슬롯 갱신이 안 되는 것.  AC 슬롯을 봐야 한다
--
-- 산출물  C:/snatcher/dump/cdb_trace_0_5_137_<시각>.tsv

local IDLE_FRAMES = 2         -- 이만큼 조용하면 CDB 한 덩어리로 끊는다
local MAX_CDB     = 24        -- 한 덩어리 상한.  넘으면 잘렸다고 남긴다
local KEEP_CDB    = 6         -- PLAY 때 거슬러 보여줄 CDB 개수

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdb_trace_0_5_137_' .. STAMP .. '.tsv'

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local SCSI_DATA = 0x1800
local K_FIN_LO, K_FIN_HI, K_RATE = 0x22A6, 0x22A7, 0x22AA

local out = io.open(PATH, 'w')
out:write('frame\tkind\tdetail\tsector\tread\tlen\tkey\tnote\n')

local function say(m) emu.log(m); print(m) end
local function rd(a) local ok,v = pcall(emu.read, a, MEM); return ok and v or 0 end
local function num(s,k) local v = s and s[k]; return type(v)=='number' and v or nil end

-- 무엇을 볼 수 있는지 한 번 적어둔다.  추측하지 않기 위해서다
do
  local ok, s = pcall(emu.getState)
  if ok and s then
    local keys = {}
    for k in pairs(s) do
      local lk = k:lower()
      if lk:find('cdrom') or lk:find('scsi') or lk:find('adpcm') or lk:find('cd') then
        keys[#keys+1] = k
      end
    end
    table.sort(keys)
    say(('상태 키 %d 개:'):format(#keys))
    for _, k in ipairs(keys) do
      say(('   %-40s = %s'):format(k, tostring(s[k])))
      out:write(('0\tSTATEKEY\t%s\t\t\t\t\t%s\n'):format(k, tostring(s[k])))
    end
  end
end

local frame, cur, lastWrite, cdbs, ncdb = 0, {}, -99, {}, 0
local playing = false

local function flushCdb()
  if #cur == 0 then return end
  local hex, trunc = {}, ''
  for i, b in ipairs(cur) do hex[i] = ('%02X'):format(b) end
  if #cur >= MAX_CDB then trunc = '★잘림' end
  local text = table.concat(hex, ' ')
  ncdb = ncdb + 1
  cdbs[ncdb] = { frame = lastWrite, text = text }
  out:write(('%d\tCDB\t%s\t\t\t\t\t%s\n'):format(lastWrite, text, trunc))
  out:flush()
  cur = {}
end

emu.addMemoryCallback(function(address, value)
  if #cur < MAX_CDB then cur[#cur + 1] = (value or 0) & 0xFF end
  lastWrite = frame
end, emu.callbackType.write, SCSI_DATA, SCSI_DATA, CPU, MEM)

local function onFrame()
  frame = frame + 1
  if #cur > 0 and (frame - lastWrite) >= IDLE_FRAMES then flushCdb() end

  local ok, s = pcall(emu.getState)
  if not ok or not s then return end

  local isPlay = s['cdrom.adpcm.playing']
  if isPlay == nil then isPlay = s['cdrom.adpcm.isPlaying'] end
  isPlay = isPlay and true or false

  if isPlay and not playing then
    if #cur > 0 then flushCdb() end          -- 재생 직전 것도 닫아서 보여준다
    local read = num(s, 'cdrom.adpcm.readAddress') or 0
    local len  = num(s, 'cdrom.adpcm.adpcmLength') or 0
    local sec  = num(s, 'cdrom.scsi.sector')
    local fin  = (rd(K_FIN_LO) | (rd(K_FIN_HI) << 8)) & 0xFFFF
    local key  = ('%04X%02X'):format(fin, rd(K_RATE) & 0xFF)
    local sat  = (len >= 0xFF00) and '★SAT' or ''

    out:write(('%d\tPLAY\t\t%s\t%04X\t%04X\t%s\t%s\n'):format(
      frame, sec and ('%06X'):format(sec) or '', read, len, key, sat))
    say(('%s PLAY f%d  key=%s read=%04X len=%04X sector=%s')
        :format(sat == '' and '     ' or sat, frame, key, read, len,
                sec and ('%06X'):format(sec) or '?'))
    for i = math.max(1, ncdb - KEEP_CDB + 1), ncdb do
      local c = cdbs[i]
      say(('        직전CDB f%-6d %s'):format(c.frame, c.text))
      out:write(('%d\tPRIOR\t%s\t\t\t\t\tPLAY f%d 직전\n'):format(c.frame, c.text, frame))
    end
    out:flush()
  end
  playing = isPlay
end

emu.addEventCallback(onFrame, emu.eventType.endFrame)
emu.addEventCallback(function() flushCdb(); out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.137-cdb-trace armed -- 순수 관측 · 게임 무수정')
say('  PLAY 행 바로 위 CDB 가 그 음성을 실어온 명령이다')
say('  ★ 정상 음성과 ★SAT 음성에서 그 관계가 다른지를 본다')
say('  ' .. PATH)
