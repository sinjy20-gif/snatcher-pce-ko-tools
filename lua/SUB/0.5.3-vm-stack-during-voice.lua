-- SUB 0.5.3 -- "음성 중에만 빌린다" 전제를 직접 확인한다 (쓰기 0 B)
--
-- 무엇이 비어 있었나
-- ---------------------------------------------------------------------------
-- subtitle_layout.py 는 이렇게 적어 두었다:
--
--     $5B80  엔진 704 B   스크립트 VM 데이터 스택.  **음성 중에만** 빌린다
--
-- 이 전제가 성립하려면 **음성 중에 게임이 그 자리를 안 써야 한다.**
-- 그런데 지금까지 잰 것은 전부 둘 중 하나였다:
--
--     (a) UI 상태          144~221 회/프레임  <- 음성이 끝나고 UI 로 복귀한 시점
--     (b) 음성 중 + 우리 엔진 이미 올라감      <- 2,755~3,425 회 폭주
--
-- 이 게임은 **음성 중에는 UI 를 절대 안 띄운다.**  같은 방에서 음성이 재생되다가
-- 정상 게임(UI)으로 돌아간다.  즉 (a)와 (b)는 겹치는 시점이 없고,
-- **"음성 중 · 우리 엔진 없음"** 은 한 번도 잰 적이 없다.
--
-- 이 판이 그것을 잰다
-- ---------------------------------------------------------------------------
-- SUB_VOICE_NO_GATE 로 게이트 승인을 안 한다.  그러면 헬퍼가 엔진을 $5B80 으로
-- **복사하지 않고** 자막도 안 나온다.  음성은 그대로 재생되고 UI 도 안 뜬다.
-- 그 상태에서 $5B80-$5E1F 쓰기를 프레임마다 세어 음성 중/밖으로 나눈다.
--
-- ★ 이 측정은 복사 시간을 버리는 게 아니라, **복사 시간을 읽는 자**를 준다
-- ---------------------------------------------------------------------------
-- 0.5.2 의 2,755~3,425 회는 entry=RTS 로 잰 값이다.  우리 엔진은 아무것도
-- 쓰지 않았다.  그러니 그 폭주는 둘 중 하나다:
--
--     (A) 헬퍼의 복사        우리 분기가 만든 것
--     (B) 게임의 정상 활동    음성 중에도 원래 쓰는 것
--
-- 이 판은 게이트를 안 열어 **복사가 아예 없다.**  같은 음성 프레임을 재면
-- (B) 만 남는다.  따라서 뺄셈이 성립한다:
--
--     0.5.2  음성 프레임 (복사 있음)   2,755 ~ 3,425 회
--     0.5.3  음성 프레임 (복사 없음)   ?
--     ────────────────────────────────────────────
--     차이 = 우리 분기가 실제로 만든 양 = 복사 시간의 실체
--
-- 판정
--     음성 중 ≈ 0 회      전제가 맞다.  그 자리는 음성 중 비어 있다
--                         -> 2,755~3,425 회 **전부가 우리 것**이다.
--                            복사 시간이 이야기의 전부가 된다
--     음성 중에도 많다    전제가 틀렸다.  게임이 음성 중에도 그 자리를 쓴다
--                         -> 우리는 살아 있는 데이터를 덮고 있고, 폭주의 일부는
--                            게임 몫이다.  자리 설계를 통째로 다시 봐야 한다
--
-- ★ voice 표본이 0 이면 판정하지 말 것.  화면의 voice:n 을 보고 판단한다.
-- ★ 자막이 안 나오는 것이 정상이다 (게이트를 안 열었으므로).
--
-- Power Cycle 뒤 이 파일 하나만 로드한다.  국장실에서 대사를 몇 개 흘리고,
-- 대사가 끝나 UI 로 돌아온 뒤에도 잠시 둔다 (두 분포를 다 채워야 한다).

SUB_VOICE_NO_GATE = true
dofile('C:/snatcher/lua/SUB/0.4.89-controller.lua')
SUB_VOICE_NO_GATE = nil

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local ENGINE_LO, ENGINE_HI = 0x5B80, 0x5E1F

local STAMP = os.date('%Y%m%d_%H%M%S')
local OUT = 'C:/snatcher/dump/vm_stack_voice_0_5_3_' .. STAMP .. '.tsv'
local out = io.open(OUT, 'w')
if out then out:write('frame\tclass\twrites\n') end

local writes = 0
emu.addMemoryCallback(function() writes = writes + 1 end,
  emu.callbackType.write, ENGINE_LO, ENGINE_HI, CPU, MEM)

local function voicePlaying()
  local ok, s = pcall(emu.getState)
  if not ok or not s then return nil end
  return s['cdrom.adpcm.playing'] == true
end

local stat = {
  voice = { n = 0, sum = 0, max = 0, zero = 0 },
  idle  = { n = 0, sum = 0, max = 0, zero = 0 },
}

local function note(class, v)
  local s = stat[class]
  s.n = s.n + 1
  s.sum = s.sum + v
  if v > s.max then s.max = v end
  if v == 0 then s.zero = s.zero + 1 end
end

local function show(class)
  local s = stat[class]
  if s.n == 0 then return class .. ':0' end
  return string.format('%s:%d 평균%.1f 최대%d 무쓰기%d%%',
                       class, s.n, s.sum / s.n, s.max,
                       math.floor(s.zero * 100 / s.n))
end

local frame, unknown = 0, 0

emu.addEventCallback(function()
  frame = frame + 1
  local n = writes
  writes = 0

  local playing = voicePlaying()
  local class
  if playing == nil then
    unknown = unknown + 1
    class = nil
  else
    class = playing and 'voice' or 'idle'
    note(class, n)
    if out then out:write(string.format('%d\t%s\t%d\n', frame, class, n)); end
  end

  if frame % 300 == 0 then
    if out then out:flush() end
    emu.log('SUB 0.5.3 분포 · ' .. show('voice') .. ' · ' .. show('idle') ..
            (unknown > 0 and (' · state불명 ' .. unknown) or ''))
  end

  emu.drawString(4, 64, string.format('0.5.3 %s | %s', show('voice'), show('idle')),
                 stat.voice.n > 0 and 0x80FF80 or 0x40C0FF, 0x000000)
end, emu.eventType.endFrame)

emu.log('SUB 0.5.3-vm-stack-during-voice armed -- 게이트 없음 · 엔진 안 올라감')
emu.log('  $5B80-$5E1F 쓰기를 음성 중/밖으로 나눠 센다')
emu.log('  ★ 자막이 안 나오는 것이 정상 · voice 표본 0 이면 판정 불가')
emu.log('  로그: ' .. OUT)
