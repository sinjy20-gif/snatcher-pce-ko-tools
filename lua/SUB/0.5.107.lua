-- SUB 0.5.107 -- 슬롯에 헬퍼를 복사해 넣는 놈이 누구인지 찾는다 (읽기 전용)
--
-- 왜 필요한가
-- ---------------------------------------------------------------------------
-- 0.5.106 은 프레임 끝마다 `ours()` 로 점유를 판정했다.  실패했다 --
-- 빌리는 구간이 **한 프레임보다 짧다.**  상주부가 매 프레임 복사해 넣고
-- 그 프레임 안에서 다 쓰므로, 프레임 끝에는 이미 VM 스택으로 돌아가 있다.
--
--   증상: 상태 줄이 계속 '슬롯 게임것' · 되돌림 diff 0/671 · 엉뚱한 시점에
--         낡은 그림자를 살아 있는 스택에 써서 게임이 멈춘다
--
-- 그래서 프레임이 아니라 **복사하는 명령 자체**에 걸어야 한다.
-- 그 PC 를 찾으면 Lua 도 네이티브도 거기서 671 B 를 뜨면 된다.
--
-- 무엇을 보나
--   $5B83 에 $AD (헬퍼 entry 첫 바이트) 가 써지는 순간의 PC
--   $5B80 에 써지는 순간의 PC (복사 시작점일 수 있다)
--   그리고 그 PC 가 몇 번 도는지
--
-- ★ 아무것도 안 쓴다.  게임 무수정.

local TAG = 'SUB 0.5.107'
local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce
local MAX_LOG = 24

local frame, logged = 0, 0
local hits = {}

local function say(fmt, ...) emu.log(TAG .. ' · ' .. string.format(fmt, ...)) end

local function getPC()
  local st = emu.getState()
  local v = st and (st['cpu.pc'] or st.pc)
  return type(v) == 'number' and math.floor(v) or -1
end

local function watch(addr, name, want)
  emu.addMemoryCallback(function(_, value)
    if want and value ~= want then return end
    local pc = getPC()
    local key = name .. pc
    hits[key] = (hits[key] or 0) + 1
    if hits[key] == 1 and logged < MAX_LOG then
      logged = logged + 1
      say('%df %s <- $%02X   pc=$%04X   ★ 처음', frame, name, value, pc)
    end
  end, emu.callbackType.write, addr, addr, CPU, MEM)
end

watch(0x5B80, '$5B80')
watch(0x5B83, '$5B83', 0xAD)

emu.addEventCallback(function() frame = frame + 1 end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('끝 -- PC 별 횟수')
  local keys = {}
  for k in pairs(hits) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do say('   %-14s %d회', k, hits[k]) end
end, emu.eventType.scriptEnded)

say('loaded -- 슬롯에 쓰는 PC 를 찾는다 (읽기 전용 · 개입 없음)')
say('오프닝 CD-DA 한 번 + 접수처 대사 한 번이면 충분하다')
