-- PROBE_ENGINE_STAGE 0.1.0  --  음성 중에만 엔진을 $5B80 에 올린다
--
-- 무엇이 달라졌나
-- ---------------
-- 앞판들은 Lua 가 **매 프레임** 훅을 심고 거뒀다.  오버레이가 갈릴 때 패치가
-- 남아서 남의 코드가 우리 자리로 뛰어드는 사고가 거기서 났다 (UI 복구 실패).
--
-- 이제 훅과 상주부는 **디스크에 구워져 있다** (`build/patch/subtitle_resident/`).
-- 오버레이와 같이 실리고 같이 사라지므로 잔류가 구조적으로 없다.
--
--     $601E   20 A0 7F EA        JSR $7FA0 / NOP   -- 디스크
--     $7FA0   상주부 32 B         매직만 보고 넘긴다 -- 디스크
--     $5B80   엔진 347 B          ★ 이 스크립트가 음성 중에만 올린다
--
-- 그래서 Lua 가 하는 일이 **음성 하나당 두 번**으로 줄었다.
--
--     재생 시작   AC 에 패턴을 넣고 $5B80 에 엔진을 올린다 (매직 SUB 포함)
--     재생 끝     매직 3 B 만 지운다 -- 상주부가 그 다음 프레임부터 안 부른다
--
-- 왜 매직만 지우나
--   `$5B80-$5E3F` 는 스크립트 VM 데이터 스택이다.  음성 중에는 깊이가 0 이라
--   (134/134 실측) 통째로 비지만, 음성이 끝나면 게임이 다시 쓴다.  우리가
--   남긴 바이트는 어차피 덮이므로 되돌릴 필요가 없다.  **부르지만 않게 하면 된다.**
--
-- ★ build/patch/subtitle_resident/ 의 디스크로 켤 것.  아니면 아무 일도 안 난다.
--
-- 출력  로그 + C:/snatcher/dump/probe_engine_stage_0_1_0_<날짜>.tsv

local MEM = emu.memType.pceMemory
local AC = emu.memType.pceArcadeCardRam
local ENGINE_AT = 0x5B80
local AC_BASE = 0x1C0000
local STUB_AT = 0x7FA0

local function slurp(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a'); f:close()
  local out = {}
  for i = 1, #data do out[i] = data:byte(i) end
  return out
end

local engine = slurp('C:/snatcher/build/cutscene_subs/engine.bin')
local patterns = slurp('C:/snatcher/build/cutscene_subs/engine_patterns.bin')

local frames, staged, cleared = 0, 0, 0
local was_playing, armed = false, false
local checked = false
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_engine_stage_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if not f then return end
  f:write('line\n')
  for _, l in ipairs(lines) do f:write(l .. '\n') end
  f:close()
end

-- 상주부가 디스크에 실제로 들어 있나.  없으면 이 스크립트는 헛돈다.
local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(STUB_AT + 1, MEM) == 0x78
       and emu.read(0x601E, MEM) == 0x20
end

local function stage()
  for i = 1, #patterns do emu.write(AC_BASE + i - 1, patterns[i], AC) end
  for i = 1, #engine do emu.write(ENGINE_AT + i - 1, engine[i], MEM) end
  staged = staged + 1
  armed = true
end

local function disarm()
  for i = 0, 2 do emu.write(ENGINE_AT + i, 0x00, MEM) end   -- 매직만
  cleared = cleared + 1
  armed = false
end

emu.addEventCallback(function()
  frames = frames + 1

  -- 오버레이 A 가 올라온 뒤에 본다.  60 프레임에 보면 아직 로드 전이라
  -- "훅이 안 보인다" 는 거짓 경보가 뜬다 (한 번 그랬다)
  if not checked and stub_ok() then
    checked = true
    say(string.format('준비됨 -- 엔진 %d B · 패턴 %d B · 훅과 상주부 확인',
          engine and #engine or 0, patterns and #patterns or 0))
  end

  if frames == 1800 and not checked then
    say('★ 상주부나 훅을 아직 못 봤다 -- build/patch/subtitle_resident/ 로 켰는지 볼 것')
    say(string.format('    $601E = %02X (20 이어야) · $7FA0 = %02X %02X (08 78 이어야)',
          emu.read(0x601E, MEM), emu.read(STUB_AT, MEM), emu.read(STUB_AT + 1, MEM)))
  end

  if not engine or not patterns then return end

  local s = emu.getState()
  local playing = s['cdrom.adpcm.playing'] == true

  if playing and not was_playing then
    stage()
    say(string.format('[프레임 %d] 음성 시작 -- 엔진을 $5B80 에 올렸다 (%d 번째)',
                      frames, staged))
  elseif not playing and was_playing and armed then
    disarm()
    say(string.format('[프레임 %d] 음성 끝 -- 매직을 지웠다 (%d 번째)', frames, cleared))
  end
  was_playing = playing

  if frames % 1800 == 0 then
    say(string.format('--- %d --- 올림 %d · 내림 %d · 지금 %s',
                      frames, staged, cleared, armed and '떠 있음' or '꺼짐'))
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_ENGINE_STAGE 0.1.0 loaded')
emu.log('  ★ build/patch/subtitle_resident/ 의 디스크로 켤 것')
emu.log('  음성이 시작되면 엔진을 $5B80 에 올리고, 끝나면 매직만 지운다')
emu.log('  훅과 상주부는 디스크에 있다 -- Lua 는 매 프레임 아무것도 안 한다')
