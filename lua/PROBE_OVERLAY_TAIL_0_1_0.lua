-- PROBE_OVERLAY_TAIL 0.1.0  --  $7CD2-$7FFF 가 정말 죽어 있나
--
-- 왜
-- --
-- 디스크 패치의 스텁을 놓을 자리를 찾는다.  섹터 251(스프라이트 오버레이 A)의
-- $7CD2-$7FFF 814 B 가 디스크에서 $FF 로 비어 있고, 그 오버레이 코드 안에서
-- 그 범위를 가리키는 명령이 **정적으로 0 개**다.
--
-- 그런데 규칙이 있다:
--
--     디스크의 FF 는 빈 공간이 아니다.
--     런타임에 죽어 있음을 여러 장면에서 증명한 뒤에 쓴다.
--
-- 정적 훑기는 계산된 주소(인덱스·간접)를 못 잡는다.  그래서 실제로 읽거나 쓰거나
-- 실행하는지를 런타임에 본다.
--
-- 참고: 오버레이 B(섹터 255)는 같은 자리에 633/814 B 의 진짜 코드가 있다.
-- 그건 문제가 아니라 오히려 좋다 -- 스텁을 오버레이 A 안에 넣으면 훅과 스텁이
-- 같이 로드되고 같이 덮인다.  다른 오버레이에는 애초에 우리 것이 없다.
-- 이 프로브는 **오버레이 A 가 살아 있는 동안**만 판정한다.
--
-- 무엇을 재나
--   읽기 · 쓰기 · 실행을 각각 센다.  누가 했는지(PC)도 같이 남긴다.
--   오버레이 A 지문이 맞는 프레임과 아닌 프레임을 갈라서 센다 --
--   오버레이 B 가 그 자리를 쓰는 것은 우리와 무관하기 때문이다.
--
-- 아무것도 안 쓴다.  대사·이동·메뉴·전투 등 장면을 두루 지나갈 것.
--
-- 출력  로그 + C:/snatcher/dump/probe_overlay_tail_0_1_0_<날짜>.tsv (600 프레임마다)

local MEM = emu.memType.pceMemory
local LO, HI = 0x7CD2, 0x7FFF

-- 오버레이 A 지문 (PROBE_SUB_LIVE 와 같은 것)
local SIG = {
  { 0x6000, { 0x20, 0x6E, 0x47 } }, { 0x6463, { 0xC2 } },
  { 0x6500, { 0x82, 0xB5, 0x00 } }, { 0x60A6, { 0xA6, 0x17 } },
}

local frames, liveA, otherA = 0, 0, 0
local hits = { read = { n = 0, inA = 0 }, write = { n = 0, inA = 0 }, exec = { n = 0, inA = 0 } }
local who = { read = {}, write = {}, exec = {} }
local logged = 0
local lines = {}
local function say(s) emu.log(s); lines[#lines+1] = s end

local function rb(a) return emu.read(a, MEM) or 0 end
local function overlayA()
  for _, s in ipairs(SIG) do
    for i = 1, #s[2] do
      if rb(s[1] + i - 1) ~= s[2][i] then return false end
    end
  end
  return true
end

local inA = false          -- 프레임 시작에 한 번만 판정한다 (콜백마다 재려면 비싸다)

local function note(kind, addr)
  local h = hits[kind]
  h.n = h.n + 1
  if inA then h.inA = h.inA + 1 end
  local pc = 0
  local ok, st = pcall(emu.getState)
  if ok and st then pc = st['cpu.pc'] or 0 end
  local key = string.format('%04X', pc)
  who[kind][key] = (who[kind][key] or 0) + 1
  if inA and logged < 12 then
    logged = logged + 1
    say(string.format('[프레임 %d] %s $%04X  (PC $%04X)  ★ 오버레이 A 중', frames, kind, addr, pc))
  end
end

emu.addMemoryCallback(function(addr) note('read', addr) end,
  emu.callbackType.read, LO, HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(addr) note('write', addr) end,
  emu.callbackType.write, LO, HI, emu.cpuType.pce, MEM)
emu.addMemoryCallback(function(addr) note('exec', addr) end,
  emu.callbackType.exec, LO, HI, emu.cpuType.pce, MEM)

local function flush()
  local f = io.open(string.format('C:/snatcher/dump/probe_overlay_tail_0_1_0_%s.tsv',
                                  os.date('%Y%m%d_%H%M%S')), 'w')
  if f then
    f:write('line\n')
    for _, l in ipairs(lines) do f:write(l .. '\n') end
    f:close()
  end
end

emu.addEventCallback(function()
  frames = frames + 1
  inA = overlayA()
  if inA then liveA = liveA + 1 else otherA = otherA + 1 end

  if frames % 600 == 0 then
    say(string.format('--- %d 프레임 --- 오버레이 A %d / 그 밖 %d', frames, liveA, otherA))
    for _, kind in ipairs({ 'read', 'write', 'exec' }) do
      local h = hits[kind]
      local top = {}
      for pc, n in pairs(who[kind]) do top[#top+1] = { pc, n } end
      table.sort(top, function(a, b) return a[2] > b[2] end)
      local list = {}
      for i = 1, math.min(4, #top) do list[#list+1] = string.format('$%s(%d)', top[i][1], top[i][2]) end
      say(string.format('    %-5s 전체 %6d · 오버레이 A 중 %6d   %s',
                        kind, h.n, h.inA, table.concat(list, ' ')))
    end
    if hits.read.inA == 0 and hits.write.inA == 0 and hits.exec.inA == 0 then
      say('    ★ 오버레이 A 가 살아 있는 동안 이 범위를 건드린 적이 없다')
    end
    flush()
  end
end, emu.eventType.startFrame)

emu.log('PROBE_OVERLAY_TAIL 0.1.0 loaded  --  아무것도 안 쓴다')
emu.log(string.format('  $%04X-$%04X 를 읽거나 쓰거나 실행하는지 본다', LO, HI))
emu.log('  대사 · 이동 · 메뉴 · 전투를 두루 지나갈 것.  오래 돌릴수록 좋다')
