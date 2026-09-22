-- SUB 0.5.108 -- 네이티브 0.4.6.59 에서 저장/반납이 **언제** 도는지 잰다
--
-- 왜
-- ---------------------------------------------------------------------------
-- 0.4.6.59 회귀: 노스킵 O · 중간 스킵 O · 접수처 O · ADPCM O · **자막 전 스킵 X**
--
-- 가설: 네이티브에는 `$8411` 스킵 처리가 없다 (그건 Lua 0.5.102 에만 있었다).
--   그래서 이른 스킵에서 state 가 2 로 남아 엔진 타이머가 ~300 프레임 더 돌고,
--   그 뒤에야 state->0 -> 그제서야 우리 복원이 돈다.  그때는 이미 챕터1
--   스크립트가 스택을 한참 쓴 뒤라 **낡은 671 B 를 살아있는 스택에 덮어쓴다.**
--
-- 재는 것
--   $7FDF 쓰기          자막 state 전이 (1 시작 · 2 활성 · 3 종료요청 · 0 유휴)
--   $5B80 쓰기 + PC     누가 슬롯을 건드리나
--                         pc=$FCDB/$FCE6/$FCF1  = 우리 복원 루프 (0.4.6.59)
--                         pc=$7FAA/$7FC3/$BE50  = 상주부의 복사
--                         pc=$5BEB/$5C3F        = 헬퍼 자기반납 STZ
--   $8411 실행          오프닝 스킵 분기
--
-- 보는 법
--   저장(state<-1) 과 복원(pc=$FCDB) 사이 프레임 수 = **낡음의 정도**
--   스킵($8411) 과 복원 사이가 크면 가설이 맞다
--
-- ★ 개입 없음.  아무것도 안 쓴다.  BIOS 는 0.4.6.59 로 두고 돌린다.

local TAG = 'SUB 0.5.108'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local STATE, SLOT, SKIP = 0x7FDF, 0x5B80, 0x8411
local MAX = 60

local frame, logged = 0, 0
local savedAt, skipAt = nil, nil
local seen = {}

local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

local function getPC()
  local st = emu.getState()
  local v = st and (st['cpu.pc'] or st.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

local function gap(from)
  return from and (frame - from) or -1
end

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addMemoryCallback(function(_, value)
  if logged >= MAX then return end
  logged = logged + 1
  if value == 0x01 then
    savedAt = frame
    say('%df state <- 1 (자막 시작 · 여기서 671 B 를 뜬다)', frame)
  else
    say('%df state <- %d   시작 뒤 %d프레임 · 스킵 뒤 %s프레임', frame, value,
        gap(savedAt), skipAt and gap(skipAt) or '-')
  end
end, emu.callbackType.write, STATE, STATE, CPU, MEM)

emu.addMemoryCallback(function(_, value)
  local pc = getPC()
  local key = pc
  seen[key] = (seen[key] or 0) + 1
  if seen[key] > 1 or logged >= MAX then return end
  logged = logged + 1
  local who = '?'
  if pc >= 0xFCBD and pc <= 0xFCFC then who = '★ 우리 복원 (0.4.6.59)'
  elseif pc >= 0x7FA0 and pc <= 0x7FDF then who = '상주부 복사'
  elseif pc >= 0x5B80 and pc <= 0x5E1E then who = '헬퍼 자기반납'
  elseif pc == 0xBE50 then who = '복사 지점 3' end
  say('%df $5B80 <- $%02X  pc=$%04X  %s   시작 뒤 %d · 스킵 뒤 %s',
      frame, value, pc, who, gap(savedAt), skipAt and gap(skipAt) or '-')
end, emu.callbackType.write, SLOT, SLOT, CPU, MEM)

emu.addMemoryCallback(function()
  skipAt = frame
  say('%df ★ SKIP@8411   state=$%02X · 시작 뒤 %d프레임',
      frame, emu.read(STATE, MEM) or 0, gap(savedAt))
end, emu.callbackType.exec, SKIP, SKIP, CPU, MEM)

emu.addEventCallback(function()
  say('끝 -- PC 별 $5B80 쓰기 횟수')
  local ks = {}
  for k in pairs(seen) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do say('   pc=$%04X  %d회', k, seen[k]) end
end, emu.eventType.scriptEnded)

say('loaded -- 0.4.6.59 용 · 읽기 전용')
say('판정: 저장(state<-1) 과 복원(pc=$FCDB) 사이가 몇 프레임인가')
