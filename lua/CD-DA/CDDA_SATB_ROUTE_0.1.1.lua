-- CDDA_SATB_ROUTE 0.1.1 -- CD-DA 컷신이 실제로 SATB를 올리는 경로를 잰다.
--
-- 0.1.0 결과: c17_001의 LBA 시계와 글리프 업로드는 성공했지만, ADPCM 자막이
-- 빌리던 $6000 -> $6463 경로의 push는 0회였다. 즉 화면에 안 보인 이유는 글자나
-- 타이밍이 아니라, CD-DA 컷신이 다른 스프라이트 업로드 루틴을 쓴다는 것이다.
--
-- 이 파일은 읽기 전용이다. c17_001 구간에서만 VDC의 SATB($1000-$10FF) 설정과
-- VWR 시작 PC를 한 프레임에 한 번씩 기록한다. POC 0.1.0과 같이 올리지 말 것.
-- 종료하지 않아도 300프레임마다 TSV를 갱신한다.

local CPU = emu.memType.cpu
local TARGET_FROM, TARGET_TO = 186750, 187370 -- c17_001.wav
local stamp = (os and os.date and os.date('%Y%m%d_%H%M%S')) or 'session'
local OUT = 'C:/snatcher/dump/cdda_satb_route_0_1_1_' .. stamp .. '.tsv'

local frame, targetFrames = 0, 0
local vdcReg, latchedLo, inSatb = 0, 0, false
local sawMarr, sawVwr = false, false
local marrPc, vwrPc = {}, {}
local marrN, vwrN, vwrWords = 0, 0, 0
local targetActive = false

local function state()
  local ok, s = pcall(emu.getState)
  return ok and s or nil
end

local function currentSector()
  local s = state()
  local sector = s and s['cdrom.audioPlayer.currentSector']
  return type(sector) == 'number' and math.floor(sector) or nil
end

local function inTarget()
  local sector = currentSector()
  return sector ~= nil and sector >= TARGET_FROM and sector <= TARGET_TO
end

local function pc()
  local s = state()
  return (s and (s['cpu.pc'] or s['cpu.programCounter'] or s.pc)) or 0
end

local function bump(table_, key)
  local item = table_[key]
  if item then item.count = item.count + 1; return end
  table_[key] = { count = 1, first = frame }
end

local function dump()
  local f = io.open(OUT, 'wb')
  if not f then emu.log('★ TSV를 못 썼다: ' .. OUT); return end
  f:write('kind\tpc\tcount\tfirst_frame\n')
  for p, item in pairs(marrPc) do
    f:write(string.format('SATB_MARR\t%04X\t%d\t%d\n', p, item.count, item.first))
  end
  for p, item in pairs(vwrPc) do
    f:write(string.format('SATB_VWR\t%04X\t%d\t%d\n', p, item.count, item.first))
  end
  f:close()
  emu.log(string.format('CDDA SATB route: 대상 %d프레임 · MAWR PC %d종 · VWR PC %d종 · VWR %d워드 -> %s',
    targetFrames, marrN, vwrN, vwrWords, OUT))
end

emu.addMemoryCallback(function(address, value)
  -- 포트 쓰기마다 getState를 부르면 SATB 256워드당 250번을 호출하게 된다.
  -- targetActive는 프레임 끝에서 한 번만 갱신한다.
  if not targetActive then return end
  if address == 0x0000 then
    vdcReg = value % 32
  elseif address == 0x0002 then
    latchedLo = value
  elseif address == 0x0003 and vdcReg == 0x00 then
    -- MAWR의 상위 바이트가 $10이면 현재 VDC 대상은 SATB word $10xx다.
    inSatb = (value == 0x10)
    if inSatb and not sawMarr then
      sawMarr = true
      local p = pc()
      if marrPc[p] == nil then marrN = marrN + 1 end
      bump(marrPc, p)
    end
  elseif address == 0x0003 and vdcReg == 0x02 and inSatb then
    vwrWords = vwrWords + 1
    if not sawVwr then
      sawVwr = true
      local p = pc()
      if vwrPc[p] == nil then vwrN = vwrN + 1 end
      bump(vwrPc, p)
    end
  end
end, emu.callbackType.write, 0x0000, 0x0003, emu.cpuType.pce, CPU)

emu.addEventCallback(function()
  frame = frame + 1
  sawMarr, sawVwr = false, false
  targetActive = inTarget()
  if targetActive then targetFrames = targetFrames + 1 end
  if frame % 300 == 0 then dump() end
end, emu.eventType.endFrame)

emu.addEventCallback(dump, emu.eventType.scriptEnded)

emu.log('CDDA_SATB_ROUTE 0.1.1 loaded -- c17_001 SATB output route probe (read-only)')
emu.log(string.format('  target LBA %06X-%06X · POC 0.1.0은 끄고 Power Cycle 뒤 이것만 올릴 것',
  TARGET_FROM, TARGET_TO))
