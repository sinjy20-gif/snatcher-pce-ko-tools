-- PROBE_VOICE_VS_TEXT 0.1.0
--
-- 무엇을 재나
-- ------------
-- "음성이 나오는 동안 게임이 대사 텍스트를 쓰는가?"  이 하나만 잰다.
--
-- 왜 필요한가
--   기존 로그(voice_events_raw / runtime_text_catalog)는 캡처 세션이 달라
--   프레임 기준이 서로 다르다.  두 로그를 겹쳐 세면 우연히 맞은 것까지
--   세어 99% 같은 헛숫자가 나온다.  그래서 한 타임라인에 둘 다 찍는다.
--
-- 무엇을 훅하나
--   $180D  ADPCM 제어.  $60 을 쓰면 재생 시작 (정본 BIOS $F61A 가 하는 일)
--   $180C  ADPCM 상태.  재생 종료 판정
--   $3619  게임 대사 버퍼.  용량 $24 바이트 (V18 이 확인해둔 값)
--
-- 판정
--   음성 구간(START~END) 안에서 $3619 대역에 쓰기가 있으면  -> 텍스트는 있다.
--                                                              게임이 안 보여줄 뿐
--   한 번도 없으면                                          -> 스크립트에 텍스트가 없다
--
-- 출력  C:/snatcher/dump/probe_voice_vs_text_0_1_0_<날짜>.tsv
--
-- 주의: 경로에 역슬래시를 쓰지 말 것.  Lua 이스케이프로 깨진다.

local mem = emu.memType.pceMemory
local BUF_LO, BUF_HI = 0x3619, 0x363C

local voiceOn, voiceStart = false, 0
local segs, cur = {}, nil
local totalWrites, frames = 0, 0

local function now() return emu.getState().ppu and emu.getState().ppu.frameCount or frames end

local function onAdpcmCtl(address, value)
  local f = now()
  if value == 0x60 and not voiceOn then          -- 재생 시작
    voiceOn, voiceStart = true, f
    cur = { start = f, writes = 0, bytes = {} }
  elseif voiceOn and (value == 0x00 or value == 0x10) then   -- 정지/리셋
    voiceOn = false
    if cur then
      cur.stop = f
      if cur.stop > cur.start then segs[#segs+1] = cur end
      cur = nil
    end
  end
end

local function onBufWrite(address, value)
  totalWrites = totalWrites + 1
  if voiceOn and cur then
    cur.writes = cur.writes + 1
    if #cur.bytes < 40 then cur.bytes[#cur.bytes+1] = value end
  end
end

local function onFrame()
  frames = frames + 1
end

local function save()
  local name = string.format('C:/snatcher/dump/probe_voice_vs_text_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if not f then emu.log('저장 실패: ' .. name) return end
  f:write('kind\tstart\tstop\tframes\tbuf_writes\tfirst_bytes\n')
  local withText, total = 0, #segs
  for _, s in ipairs(segs) do
    if s.writes > 0 then withText = withText + 1 end
    local hex = {}
    for _, b in ipairs(s.bytes) do hex[#hex+1] = string.format('%02X', b) end
    f:write(string.format('SEG\t%d\t%d\t%d\t%d\t%s\n',
            s.start, s.stop, s.stop - s.start, s.writes, table.concat(hex, ' ')))
  end
  f:write(string.format('TOTAL\t\t\t\t%d\t음성구간 %d개 · 그중 버퍼쓰기 있음 %d개\n',
          totalWrites, total, withText))
  f:close()
  emu.log(string.format('PROBE_VOICE_VS_TEXT 0.1.0 -> %s', name))
  emu.log(string.format('  음성구간 %d개 · 그중 대사버퍼에 쓴 것 %d개 · 전체 버퍼쓰기 %d회',
          total, withText, totalWrites))
end

emu.addMemoryCallback(onAdpcmCtl, emu.callbackType.write, 0x180D, 0x180D, emu.cpuType.pce, mem)
emu.addMemoryCallback(onBufWrite, emu.callbackType.write, BUF_LO, BUF_HI, emu.cpuType.pce, mem)
emu.addEventCallback(onFrame, emu.eventType.startFrame)
emu.addEventCallback(save, emu.eventType.scriptEnded)

emu.log('PROBE_VOICE_VS_TEXT 0.1.0 loaded')
emu.log('  음성 대사가 나오는 장면을 몇 개 지나간 뒤 스크립트를 정지하면 저장된다')
