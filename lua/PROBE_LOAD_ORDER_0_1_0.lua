-- PROBE_LOAD_ORDER 0.1.0  --  AC 자막 팩이 오버레이 A 보다 먼저 올라오나
--
-- 왜
-- --
-- 디스크에 훅을 박으면 (`$601E  A9 3F 85 17 -> 20 40 5C EA`) 그 훅은 **오버레이 A 가
-- 로드될 때마다 같이 온다.**  잔류 문제가 구조적으로 사라진다는 것이 장점이다.
--
-- 그런데 한 가지 창이 남는다:
--
--     펌웨어가 $5C40 에 스텁을 올리기 **전에** 오버레이 A 가 로드되면
--     JSR $5C40 이 그 자리의 게임 데이터를 실행한다
--
-- `SUBTITEL 0.2.5` 가 정확히 이 부류로 부팅에서 멈췄다 (BREAKTHROUGH §1.1) --
-- 로더가 AC 를 아직 안 채웠는데 케이브가 $5B80 에 쓰레기를 넣고 벡터가 그것을
-- 가리켰다.  그때 나온 대응이 0.2.7 의 AC 매직 검사다.
--
-- 다만 **창이 애초에 없을 수도 있다.**  순서가 이렇기 때문이다:
--
--     부팅 -> AC 팩 적재 -> 펌웨어 설치 -> 게임 진행 -> 오버레이 A 로드
--
-- AC 팩은 부팅 때 올라가고 오버레이 A 는 실제 게임 화면에서야 로드된다.
-- 그러면 훅이 실행될 때는 이미 스텁이 있다.  **재보면 안다.**
--
-- 무엇을 재나
--   프레임마다 세 가지 시점을 찍는다.
--     A  AC 자막 예약 구역($1C0000)이 유효해지는 순간
--        -- 0 이 아닌 바이트가 나타나면 무언가 올라온 것이다
--     B  $5C40 에 코드로 보이는 것이 들어오는 순간 (펌웨어 설치)
--     C  오버레이 A 가 처음 로드되는 순간 (지문 일치)
--   C 가 A·B 보다 뒤면 창이 없다.  앞이면 창이 있고 그 길이가 위험 구간이다.
--
-- 아무것도 안 쓴다.  **부팅부터 켜고 첫 대사 장면까지 지나갈 것.**
--
-- 출력  로그 + C:/snatcher/dump/probe_load_order_0_1_0_<날짜>.tsv

local MEM, AC = emu.memType.pceMemory, emu.memType.pceArcadeCardRam
local AC_SUB_BASE = 0x1C0000        -- manifest: subtitle_reserve_base
local STUB = 0x5C40                 -- manifest: subtitle_ram_code = 5C40-5E1F

-- 오버레이 A 지문 (섹터 251 의 스프라이트 엔진)
local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x601E, { 0xA9, 0x3F, 0x85, 0x17 } },
  { 0x6463, { 0xC2 } }, { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local frames = 0
local first_ac, first_stub, first_overlay = -1, -1, -1
local overlay_frames, ac_bytes = 0, 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function rb(a, t) return emu.read(a, t or MEM) or 0 end

local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if rb(s[1] + i - 1) ~= s[2][i] then return false end
    end
  end
  return true
end

-- AC 자막 구역에 무언가 올라왔나.  앞 256 B 를 훑어 0 아닌 바이트를 센다
local function ac_live()
  local n = 0
  for i = 0, 255 do
    if rb(AC_SUB_BASE + i, AC) ~= 0 then n = n + 1 end
  end
  return n
end

-- $5C40 이 코드처럼 보이나.  게임 데이터면 대개 0 이거나 반복 패턴이다.
-- 우리 스텁은 PHP(08) SEI(78) 로 시작한다.
local function stub_live()
  return rb(STUB) == 0x08 and rb(STUB + 1) == 0x78
end

local function snapshot(tag)
  local b = {}
  for i = 0, 7 do b[#b+1] = string.format('%02X', rb(STUB + i)) end
  return string.format('%s  $5C40 = %s · AC 비영 %d/256', tag, table.concat(b, ' '), ac_bytes)
end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_load_order_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, l in ipairs(lines) do f:write(l .. '\n') end
    f:close()
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  ac_bytes = ac_live()

  if first_ac < 0 and ac_bytes > 0 then
    first_ac = frames
    say(string.format('[프레임 %d] ★ A  AC 자막 구역에 데이터가 나타났다 (%d/256 비영)',
                      frames, ac_bytes))
  end
  if first_stub < 0 and stub_live() then
    first_stub = frames
    say(string.format('[프레임 %d] ★ B  $5C40 에 스텁이 올라왔다', frames))
  end

  local live = overlayA()
  if live then overlay_frames = overlay_frames + 1 end
  if first_overlay < 0 and live then
    first_overlay = frames
    say(string.format('[프레임 %d] ★ C  오버레이 A 가 처음 로드됐다', frames))
    say('    ' .. snapshot('그 순간'))
    -- 판정
    if first_stub > 0 and first_stub <= frames then
      say('    -> 창 없음.  훅이 실행될 때 스텁이 이미 있다')
    else
      say(string.format('    -> ★ 창 있음.  스텁이 아직 없는데 오버레이 A 가 로드됐다'))
      say('       디스크에 JSR 을 박으면 이 구간에서 게임 데이터를 실행한다')
    end
  end

  if frames % 600 == 0 then
    say(string.format('--- %d --- A(AC) %s · B(스텁) %s · C(오버레이) %s · 오버레이 프레임 %d',
          frames,
          first_ac > 0 and tostring(first_ac) or '아직',
          first_stub > 0 and tostring(first_stub) or '아직',
          first_overlay > 0 and tostring(first_overlay) or '아직',
          overlay_frames))
    say('    ' .. snapshot('현재'))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_LOAD_ORDER 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log('  ★ 부팅부터 켜고 첫 대사 장면까지 지나갈 것')
emu.log('  AC 자막 구역 · $5C40 스텁 · 오버레이 A 의 등장 순서를 찍는다')
