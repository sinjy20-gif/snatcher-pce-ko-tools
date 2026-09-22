-- PROBE_INJECT_TEXT 0.1.0
--
-- 무엇을 증명하나
-- ----------------
-- "음성 재생 중에 우리가 $3619 에 텍스트를 써넣으면 게임이 그려주는가?"
--
-- 여기까지 확인된 것 (PROBE_VOICE_VS_TEXT 0.1.1)
--   $3619 은 대사 버퍼가 맞다.  일반 대사가 Shift-JIS 로 흘러간다
--     예)  83 6E 83 8A 81 5B FF   =  "ハリー" + 종료
--   음성 구간 14 개에서 버퍼 쓰기가 0 회.  게임은 음성 중에 텍스트를 안 만든다
--
-- 그래서 남은 질문이 이것 하나다.  구멍은 있는데, 그 구멍이 음성 중에도
-- 열려 있느냐.  게임이 그때 렌더러를 아예 안 부르면 써봐야 소용이 없다.
--
-- 두 가지를 동시에 본다
--   1  주입   음성 시작 후 N 프레임에 짧은 문자열을 버퍼에 쓴다
--   2  읽기   $3619 대역을 게임이 읽는지 센다.  음성 중 / 음성 밖 따로
--
-- 판정
--   음성 중 읽기 있음 + 화면에 글자 뜸    -> 끝.  이 경로로 자막 간다
--   음성 중 읽기 있음 + 화면에 안 뜸      -> 렌더러는 도는데 다른 조건이 막는다
--   음성 중 읽기 0                        -> 렌더러가 안 불린다.  따로 깨워야 한다
--
-- 안전
--   버퍼 용량은 $24 (36) 바이트.  넘기면 뒤가 깨진다 (V18 이 확인).
--   여기서는 7 바이트만 쓴다.  그래도 세이브는 미리 떠둘 것.
--
-- 출력  C:/snatcher/dump/probe_inject_text_0_1_0_<날짜>.tsv

local mem = emu.memType.pceMemory
local BUF_LO, BUF_HI = 0x3619, 0x363C
local DELAY = 20                       -- 음성 시작 후 몇 프레임 뒤에 넣나

-- テスト + 종료.  카타카나라 화면에서 바로 눈에 띈다
local PAYLOAD = { 0x83,0x65, 0x83,0x58, 0x83,0x67, 0xFF }

local voiceOn, voiceStart = false, 0
local injected, armed = 0, false
local frames = 0
local readsIn, readsOut = 0, 0
local writesIn, writesOut = 0, 0
local segs, cur = {}, nil

local function onAdpcmCtl(address, value)
  if value == 0x60 and not voiceOn then
    voiceOn, voiceStart, armed = true, frames, true
    cur = { start = frames, reads = 0, injected = false }
  elseif voiceOn and (value == 0x00 or value == 0x10) then
    voiceOn, armed = false, false
    if cur then
      cur.stop = frames
      if cur.stop > cur.start then segs[#segs+1] = cur end
      cur = nil
    end
  end
end

local function onRead(address, value)
  if voiceOn then
    readsIn = readsIn + 1
    if cur then cur.reads = cur.reads + 1 end
  else
    readsOut = readsOut + 1
  end
end

local function onWrite(address, value)
  if voiceOn then writesIn = writesIn + 1 else writesOut = writesOut + 1 end
end

local function onFrame()
  frames = frames + 1
  if armed and voiceOn and frames - voiceStart >= DELAY then
    for i, b in ipairs(PAYLOAD) do
      emu.write(BUF_LO + i - 1, b, mem)
    end
    injected = injected + 1
    armed = false
    if cur then cur.injected = true end
    emu.log(string.format('주입 #%d  프레임 %d  ($3619 에 7 바이트)', injected, frames))
  end
end

local function save()
  local name = string.format('C:/snatcher/dump/probe_inject_text_0_1_0_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if not f then emu.log('저장 실패: ' .. name) return end
  f:write('kind\tstart\tstop\tframes\treads\tinjected\n')
  for _, s in ipairs(segs) do
    f:write(string.format('SEG\t%d\t%d\t%d\t%d\t%s\n',
            s.start, s.stop, s.stop - s.start, s.reads, s.injected and 'yes' or 'no'))
  end
  f:write(string.format('TOTAL\t%d\t%d\t%d\t%d\t%d\n',
          #segs, injected, readsIn, readsOut, writesIn))
  f:close()

  emu.log('PROBE_INJECT_TEXT 0.1.0 -> ' .. name)
  emu.log(string.format('  음성구간 %d개 · 주입 %d회', #segs, injected))
  emu.log(string.format('  버퍼 읽기  음성중 %d회 · 음성밖 %d회', readsIn, readsOut))
  emu.log(string.format('  버퍼 쓰기  음성중 %d회 (우리 주입 포함) · 음성밖 %d회',
          writesIn, writesOut))
  if readsIn == 0 then
    emu.log('  ★ 음성 중 버퍼 읽기가 0 -- 렌더러가 안 불린다.  따로 깨워야 한다')
  else
    emu.log('  ★ 음성 중에도 버퍼를 읽는다 -- 화면에 テスト 가 떴는지 눈으로 확인할 것')
  end
end

emu.addMemoryCallback(onAdpcmCtl, emu.callbackType.write, 0x180D, 0x180D, emu.cpuType.pce, mem)
emu.addMemoryCallback(onRead,  emu.callbackType.read,  BUF_LO, BUF_HI, emu.cpuType.pce, mem)
emu.addMemoryCallback(onWrite, emu.callbackType.write, BUF_LO, BUF_HI, emu.cpuType.pce, mem)
emu.addEventCallback(onFrame, emu.eventType.startFrame)
emu.addEventCallback(save, emu.eventType.scriptEnded)

emu.log('PROBE_INJECT_TEXT 0.1.0 loaded')
emu.log('  음성 대사 장면을 지나가면서 화면에 テスト 가 뜨는지 볼 것')
emu.log('  세이브 먼저 떠둘 것 -- 버퍼에 직접 쓴다')
