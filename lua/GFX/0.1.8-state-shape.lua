-- PROBE GFX 0.1.8 -- `emu.getState()` 가 어떻게 생겼는지 찍는다
--
-- ★ 순수 관측.  한 번 찍고 끝난다.
--
-- 왜
-- --
-- 0.1.7 이 VDC 포트 쓰기를 63 만 회 잡았는데 **PC 를 하나도 못 읽었다.**
-- `state.cpu.pc` 를 짐작으로 썼는데 그 자리가 아니었다 ($FFFFFFFF = -1).
--
-- 이름을 또 짐작하지 말고 **실물을 찍어서** 필드 이름을 확인한다.
-- (오늘만 이름을 믿었다가 세 번 틀렸다: CD_SUBQ 재동기 · 스프라이트 64 개 ·
--  타일 플레인 배치)
--
-- 산출물  콘솔에만 찍는다.  키 이름을 보고 다음 프로브에서 제대로 쓰면 된다.

local function say(m) emu.log(m); print(m) end

local function dump(t, prefix, depth)
  if depth > 3 then return end
  if type(t) ~= 'table' then
    say(('%s= %s (%s)'):format(prefix, tostring(t), type(t)))
    return
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  say(('%s{ %s }'):format(prefix, table.concat(keys, ', ')))
  for _, k in ipairs(keys) do
    local v = t[k] ~= nil and t[k] or t[tonumber(k)]
    if type(v) == 'table' then
      dump(v, prefix .. k .. '.', depth + 1)
    elseif type(v) == 'number' then
      say(('%s%s = %d ($%X)'):format(prefix, k, v, v))
    end
  end
end

local done = false
emu.addEventCallback(function()
  if done then return end
  done = true
  say('')
  say('=== emu.getState() 구조 ===')
  local st = emu.getState()
  if st == nil then
    say('  ★nil 이다 -- 이 빌드에서는 getState 를 못 쓴다')
  else
    dump(st, '  ', 1)
  end
  say('')
  say('=== 그 밖에 있는 것 ===')
  for _, name in ipairs({ 'getLabelAddress', 'getScriptDataFolder',
                          'getState', 'getMemoryState', 'getPrgRomOffset' }) do
    say(('  emu.%s  %s'):format(name, type(emu[name])))
  end
  say('')
  say('★위에서 PC 로 보이는 필드 이름을 알려주면 다음 프로브에 넣는다')
end, emu.eventType.endFrame)

say('PROBE GFX 0.1.8-state-shape armed -- 첫 프레임에 한 번만 찍는다')
