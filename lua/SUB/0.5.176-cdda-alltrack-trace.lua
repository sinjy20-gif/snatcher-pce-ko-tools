-- SUB 0.5.176 -- 전 트랙 연결(0.4.7.11)이 어디서 끊기나
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 트랙 17 하나만 붙어 있던 것을 15 트랙으로 늘렸더니 **자막이 아예 안 나온다.**
-- 짐작으로 두 번 고쳤는데 (ADPCM 즉치 오프셋 오용 · 헬퍼 제어블록 상수) 여전하다.
-- 그러니 사슬을 따라가며 **어디서 멈추는지** 잰다.
--
-- 사슬 (뱅크 $01 · 0.4.7.11 실측 주소)
-- -----------------------------------
--     $F836  cdda_check        여기까지 오나
--     $F841  cdda_pulse_ok     시작 펄스 게이트를 통과하나
--     $F85F  cdda_dir_loop     디렉터리 검색이 도나
--     $F879  cdda_start        ★트랙을 찾았나
--     $ECF9  scheduler_cdda    스케줄러가 도나
--     $F3C7  cdda_sched_near   디스패처가 스케줄러로 보내나
--
-- ⚠ MPR7 이 뱅크 $00 이면 같은 주소가 원본 시스템카드다.  창($FFD4 열기 ·
--   $F050 닫기)을 따로 세서 **뱅크 $01 인 동안의 접촉만** 센다
--   (0.5.172 에서 확인한 함정).  $ECF9 는 그 창 안이다.
--
-- 그리고 무장 뒤 렌더러가 어떤 상태인지 본다 (CPU RAM 이라 그냥 읽힌다)
-- --------------------------------------------------------------------
--     $5B80+0..2   매직 'SUB'          엔진이 올라왔나
--     $5B80+203    vram_base_hi_imm    ★$79 여야 한다 (트랙 17)
--     $5B80+238    pattern_base_lo     ★$C8
--     $5B80+243    pattern_attr        ★$BF
--     $5B80+326    ready               $FF(아직 안 그림) -> 0 -> 1
--     $5B80+327    record_ptr lo       스케줄러가 구간마다 갈아끼운다
--     $5B80+330    count               표시 레코드 헤더
--     $5B80+660    ★트랙 BCD           cdda_start 가 심는다.  $17 이어야 한다
--     $5B80+670    매체 지문            $CD 여야 한다
--
-- 읽는 법
-- -------
--     cdda_check 0        디스패처가 거기까지 안 온다 (STATE/슬롯 문제)
--     pulse_ok 0          시작 펄스를 못 봤다
--     dir_loop 돌고 start 0   ★디렉터리에서 트랙을 못 찾는다
--     start 는 도는데 매직 없음  엔진 복사/STATE=1 문제
--     매직은 있는데 +660 이 $17 아님  ★디렉터리 스트리밍이 어긋났다
--     +203 이 $79 아님    ★즉치 자리가 틀렸다
--     scheduler 0         디스패처가 스케줄러로 안 보낸다 (지문 불일치)
--
-- 산출물  C:/snatcher/dump/alltrack_0_5_176_<시각>.tsv

local MEM, CPU = emu.memType.pceMemory, emu.cpuType.pce

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/alltrack_0_5_176_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tkind\tname\tdetail\n')

local function say(m) emu.log(m); print(m) end

local SITES = {
  { name = 'cdda_check',   addr = 0xF836 },
  { name = 'pulse_ok',     addr = 0xF841 },
  { name = 'dir_loop',     addr = 0xF85F },
  { name = 'cdda_start',   addr = 0xF879 },
  { name = 'sched_near',   addr = 0xF3C7 },
  { name = 'scheduler',    addr = 0xECF9 },
}

local ENG = 0x5B80
local FIELDS = {
  { name = 'magic0',    at = ENG + 0,   want = 0x53 },
  { name = 'magic1',    at = ENG + 1,   want = 0x55 },
  { name = 'vram_hi',   at = ENG + 203, want = 0x79 },
  { name = 'pat_lo',    at = ENG + 238, want = 0xC8 },
  { name = 'pat_attr',  at = ENG + 243, want = 0xBF },
  { name = 'ready',     at = ENG + 326 },
  { name = 'recptr_lo', at = ENG + 327 },
  { name = 'count',     at = ENG + 330 },
  { name = 'trackbcd',  at = ENG + 660, want = 0x17 },
  { name = 'magicCD',   at = ENG + 670, want = 0xCD },
}

local frame = 0
local bank1 = false
local hits = {}
for _, s in ipairs(SITES) do hits[s.name] = 0 end

emu.addMemoryCallback(function() bank1 = true end,
                      emu.callbackType.exec, 0xFFD4, 0xFFD4, CPU, MEM)
emu.addMemoryCallback(function() bank1 = false end,
                      emu.callbackType.exec, 0xF050, 0xF050, CPU, MEM)

for _, s in ipairs(SITES) do
  local nm, ad = s.name, s.addr
  emu.addMemoryCallback(function()
    if not bank1 then return end
    hits[nm] = hits[nm] + 1
    if hits[nm] == 1 then
      say(('★처음 도달  f%-7d %-12s $%04X'):format(frame, nm, ad))
      out:write(('%d\tSITE\t%s\t%04X\n'):format(frame, nm, ad))
      out:flush()
    end
  end, emu.callbackType.exec, ad, ad, CPU, MEM)
end

local shown = 0
local lastState = -1

emu.addEventCallback(function()
  frame = frame + 1
  local st = emu.read(0x7FDF, MEM, false) or -1
  if st ~= lastState then
    if st == 0x01 or st == 0x02 or st == 0x03 then
      say(('  STATE f%-7d -> $%02X'):format(frame, st))
      out:write(('%d\tSTATE\t%02X\t\n'):format(frame, st))
    end
    lastState = st
  end
  -- STATE 2 에 처음 들어간 뒤 몇 번만 렌더러 상태를 찍는다
  if st == 0x02 and shown < 3 and frame % 30 == 0 then
    shown = shown + 1
    local parts = {}
    for _, f in ipairs(FIELDS) do
      local v = emu.read(f.at, MEM, false) or -1
      local mark = ''
      if f.want and v ~= f.want then mark = ('!=%02X'):format(f.want) end
      parts[#parts + 1] = ('%s=%02X%s'):format(f.name, v, mark)
    end
    local line = ('  렌더러 f%-7d %s'):format(frame, table.concat(parts, ' '))
    say(line)
    out:write(('%d\tRENDER\t\t%s\n'):format(frame, table.concat(parts, ' ')))
    out:flush()
  end
  if frame % 900 == 0 then
    local parts = {}
    for _, s in ipairs(SITES) do parts[#parts + 1] = ('%s=%d'):format(s.name, hits[s.name]) end
    say(('심박 f%-7d STATE=$%02X  %s'):format(frame, st, table.concat(parts, ' ')))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  say('')
  say('끝 -- 사슬 도달 횟수 (뱅크 $01 인 동안만)')
  out:write('#\n')
  for _, s in ipairs(SITES) do
    local line = ('  %-12s $%04X  x%d'):format(s.name, s.addr, hits[s.name])
    say(line); out:write('# ' .. line .. '\n')
  end
  out:close()
  say('')
  if hits['cdda_start'] == 0 and hits['dir_loop'] > 0 then
    say('  ★디렉터리에서 트랙을 못 찾았다.  raw 키($26F9 & $7F)를 확인할 것')
  elseif hits['dir_loop'] == 0 and hits['pulse_ok'] > 0 then
    say('  ★검색에 못 들어갔다')
  elseif hits['pulse_ok'] == 0 and hits['cdda_check'] > 0 then
    say('  ★시작 펄스($263C|$2638)를 못 봤다')
  elseif hits['cdda_check'] == 0 then
    say('  ★cdda_check 까지 못 온다.  STATE 나 AC 슬롯 쪽')
  elseif hits['scheduler'] == 0 then
    say('  ★무장은 됐는데 스케줄러가 안 돈다.  매체 지문($5B80+670)을 볼 것')
  end
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.176-cdda-alltrack-trace armed -- 순수 관측 (0.4.7.11 에 올릴 것)')
say('  오프닝을 자막 구간까지 틀고 30 초쯤 두면 된다')
say('  ' .. PATH)
