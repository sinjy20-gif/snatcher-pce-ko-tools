-- PROBE_VOICE_VS_TEXT 0.1.1
--
-- 0.1.0 에서 바뀐 것
-- ------------------
-- 0.1.0 은 "음성 구간 50개 전부 $3619 쓰기 0" 을 냈다.  훅은 살아 있었다
-- (전체 3932 회 잡힘).  그런데 $3619 가 지금 빌드에서도 대사 버퍼인지
-- 확인이 안 됐다.  V18 주석(7월)에만 있던 값이고 코드베이스 어디에도 없다.
--
-- 그래서 이 판은 **버퍼의 정체부터 증명한다.**
--   - 음성 밖에서 일어난 쓰기도 값까지 남긴다
--   - 값이 텍스트인지 판정한다 (Shift-JIS 8140-9FFF / E040-EFFF, 커스텀 F0xx)
--   - 텍스트가 아니면 $3619 는 대사 버퍼가 아니다 -> 0.1.0 결론은 무효
--
-- 판정표
--   음성밖 쓰기가 텍스트고, 음성중 쓰기가 0     -> 스크립트에 음성용 텍스트가 없다
--   음성밖 쓰기가 텍스트가 아님                 -> 버퍼 주소가 틀렸다.  다시 찾아야 함
--   음성중에도 텍스트 쓰기가 있음               -> 텍스트는 있고 표시만 억제된다
--
-- 출력  C:/snatcher/dump/probe_voice_vs_text_0_1_1_<날짜>.tsv

local mem = emu.memType.pceMemory
local BUF_LO, BUF_HI = 0x3619, 0x363C

local voiceOn = false
local segs, cur = {}, nil
local frames = 0
local outside, inside = {}, {}      -- 음성 밖 / 음성 중 쓰기 표본
local nOut, nIn = 0, 0

local function looksText(v)
  -- Shift-JIS 선행바이트, 또는 커스텀 F0 대역, 또는 ASCII 표시가능
  return (v >= 0x81 and v <= 0x9F) or (v >= 0xE0 and v <= 0xEF)
      or v == 0xF0 or (v >= 0x20 and v <= 0x7E)
end

local function onAdpcmCtl(address, value)
  if value == 0x60 and not voiceOn then
    voiceOn = true
    cur = { start = frames, writes = 0 }
  elseif voiceOn and (value == 0x00 or value == 0x10) then
    voiceOn = false
    if cur then
      cur.stop = frames
      if cur.stop > cur.start then segs[#segs+1] = cur end
      cur = nil
    end
  end
end

local function onBufWrite(address, value)
  if voiceOn then
    nIn = nIn + 1
    if cur then cur.writes = cur.writes + 1 end
    if #inside < 64 then inside[#inside+1] = { frames, address, value } end
  else
    nOut = nOut + 1
    if #outside < 64 then outside[#outside+1] = { frames, address, value } end
  end
end

local function onFrame() frames = frames + 1 end

local function save()
  local name = string.format('C:/snatcher/dump/probe_voice_vs_text_0_1_1_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if not f then emu.log('저장 실패: ' .. name) return end
  f:write('kind\ta\tb\tc\td\n')

  local withText = 0
  for _, s in ipairs(segs) do
    if s.writes > 0 then withText = withText + 1 end
    f:write(string.format('SEG\t%d\t%d\t%d\t%d\n', s.start, s.stop, s.stop - s.start, s.writes))
  end

  local textish = 0
  for _, w in ipairs(outside) do
    if looksText(w[3]) then textish = textish + 1 end
    f:write(string.format('OUT\t%d\t%04X\t%02X\t%s\n', w[1], w[2], w[3],
            looksText(w[3]) and 'text' or '-'))
  end
  for _, w in ipairs(inside) do
    f:write(string.format('IN\t%d\t%04X\t%02X\t%s\n', w[1], w[2], w[3],
            looksText(w[3]) and 'text' or '-'))
  end

  f:write(string.format('TOTAL\t%d\t%d\t%d\t%d\n', #segs, withText, nOut, nIn))
  f:close()

  emu.log('PROBE_VOICE_VS_TEXT 0.1.1 -> ' .. name)
  emu.log(string.format('  음성구간 %d개 · 그중 버퍼쓰기 있음 %d개', #segs, withText))
  emu.log(string.format('  버퍼쓰기  음성밖 %d회 · 음성중 %d회', nOut, nIn))
  emu.log(string.format('  ★ 음성밖 표본 %d개 중 텍스트로 보이는 값 %d개', #outside, textish))
  if #outside > 0 and textish * 2 < #outside then
    emu.log('  ★★ 텍스트가 아니다 -- $3619 는 대사 버퍼가 아닐 가능성이 크다')
  end
end

emu.addMemoryCallback(onAdpcmCtl, emu.callbackType.write, 0x180D, 0x180D, emu.cpuType.pce, mem)
emu.addMemoryCallback(onBufWrite, emu.callbackType.write, BUF_LO, BUF_HI, emu.cpuType.pce, mem)
emu.addEventCallback(onFrame, emu.eventType.startFrame)
emu.addEventCallback(save, emu.eventType.scriptEnded)

emu.log('PROBE_VOICE_VS_TEXT 0.1.1 loaded')
emu.log('  일반 대사(음성 없는 것) 몇 줄 + 음성 대사 몇 개를 지나가고 정지할 것')
