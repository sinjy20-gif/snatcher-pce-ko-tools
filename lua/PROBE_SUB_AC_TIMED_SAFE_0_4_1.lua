-- PROBE_SUB_AC_TIMED_SAFE 0.4.1
-- 0.4.0 UI 복귀 실패 수정: 엔진을 $5B80-$5E1E로 제한해 $5E20-$5E3F를 건드리지 않는다.
-- ★ 2026-08-24 실측 통과: 두 조각 자체 전환 · tail diff 0/32 · 실제 UI 복귀 확인.

local MEM, AC, VRAM = emu.memType.pceMemory, emu.memType.pceArcadeCardRam,
                       emu.memType.pceVideoRam
local ENGINE_AT, STUB_AT, PACK_AT = 0x5B80, 0x7FA0, 0x1C0000
local TAIL_LO, TAIL_HI = 0x5E20, 0x5E3F
local PAT_VRAM_WORD, VRAM_WORDS = 0x7900, 19 * 0x40
local PAT_VRAM_BYTE, VRAM_BYTES = PAT_VRAM_WORD * 2, VRAM_WORDS * 2
local KEY = { 0x78, 0x30, 0x00, 0x00, 0x68, 0x0E }
-- engine_ac_timed_safe_poc.json 생성 오프셋
local OFF_READY, OFF_COUNT, OFF_SELECTOR, OFF_ELAPSED, OFF_RECORD = 364, 365, 366, 455, 461
local ENGINE_PATH = 'C:/snatcher/build/cutscene_subs/engine_ac_timed_safe_poc.bin'
local PACK_PATH = 'C:/snatcher/build/cutscene_subs/subtitle_pack.bin'

local function slurp(path)
  local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
  local d = f:read('*a'); f:close()
  local t = {}; for i = 1, #d do t[i] = d:byte(i) end
  return t
end
local engine, pack = slurp(ENGINE_PATH), slurp(PACK_PATH)
local function u8(o) return pack[o + 1] end
local function u16(o) return u8(o) | (u8(o + 1) << 8) end
local function u32(o) return u16(o) | (u16(o + 2) << 16) end
assert(#engine <= 672, string.format('safe engine crossed $5E20: %d B', #engine))
for i = 0, 5 do
  assert((emu.read(PACK_AT + i, AC) or -1) == u8(i),
         'AC pack differs; run LOAD_SUBTITLE_PACK_AC_0_1_0.lua again')
end

local P = { count=u16(14), index=u32(16), records=u32(26), chars=u32(38),
            stride=u8(42), cell=u8(35) }
local expected = {}
for i = 0, P.count - 1 do
  local at, same = P.index + i * P.stride, true
  for k = 0, 5 do if u8(at + k) ~= KEY[k + 1] then same = false; break end end
  if same then expected[#expected + 1] = {frame=u16(at + 7), rec=u32(at + 9)} end
end
assert(#expected == 2 and expected[2].frame == 120, 'target pack entries changed')

local function text_at(rec)
  local at, out = P.records + rec, ''
  for i = 0, u8(at) - 1 do
    local cell = at + 6 + i * P.cell
    out = out .. utf8.char(u16(P.chars + u16(cell) * 2))
  end
  return out
end
local function loaded_text()
  local n, out = emu.read(ENGINE_AT + OFF_COUNT, MEM) or 0, ''
  for i = 0, n - 1 do
    local at = ENGINE_AT + OFF_RECORD + 6 + i * 4
    local id = (emu.read(at, MEM) or 0) | ((emu.read(at + 1, MEM) or 0) << 8)
    out = out .. utf8.char(u16(P.chars + id * 2))
  end
  return out
end

local frames, was_playing, armed, checked = 0, false, false, false
local inspect1, inspect2, vram_backup, tail_backup = 0, 0, nil, nil
local function stub_ok()
  return emu.read(STUB_AT, MEM) == 0x08 and emu.read(0x601E, MEM) == 0x20
end
local function save_guards()
  -- Mesen pceVideoRam은 byte 주소: VDC word $7900 = mem byte $F200.
  vram_backup = {}; for i=0,VRAM_BYTES-1 do vram_backup[i]=emu.read(PAT_VRAM_BYTE+i,VRAM) or 0 end
  tail_backup = {}; for a=TAIL_LO,TAIL_HI do tail_backup[a]=emu.read(a,MEM) or 0 end
end
local function tail_diff()
  local bad=0; for a=TAIL_LO,TAIL_HI do if (emu.read(a,MEM) or 0)~=tail_backup[a] then bad=bad+1 end end
  return bad
end
local function restore_vram()
  for i=0,VRAM_BYTES-1 do emu.write(PAT_VRAM_BYTE+i,vram_backup[i],VRAM) end
end

local function stage()
  save_guards()
  for i=1,#engine do emu.write(ENGINE_AT+i-1,engine[i],MEM) end
  for i=1,6 do emu.write(ENGINE_AT+OFF_SELECTOR+i-1,KEY[i],MEM) end
  armed, inspect1, inspect2 = true, frames+8, frames+128
  emu.log(string.format('[%d] AC TIMED SAFE START · 엔진 %d B · $5E20-$5E3F 미사용',frames,#engine))
  emu.log('  음성 키 6 B 한 번 · 이후 Lua 조각 제어 0 B')
end
local function inspect(part)
  local actual, wanted = loaded_text(), text_at(expected[part].rec)
  local ready, elapsed = emu.read(ENGINE_AT+OFF_READY,MEM) or 0,
                         emu.read(ENGINE_AT+OFF_ELAPSED,MEM) or 0
  local bad = tail_diff()
  emu.log(string.format('  자체검사 %d/2 · elapsed=%d · ready=%d · tail diff=%d/32 · "%s"',
                        part,elapsed,ready,bad,actual))
  if ready==1 and actual==wanted and bad==0 then
    emu.log('  ★ AC TIMED SAFE PASS: 자체 전환 정상 · 금지 RAM 무변화')
  else
    emu.log(string.format('  ★ AC TIMED SAFE FAIL: 기대="%s"',wanted))
  end
end
local function disarm()
  for i=0,2 do emu.write(ENGINE_AT+i,0,MEM) end
  restore_vram()
  local bad=tail_diff()
  emu.log(string.format('[%d] AC TIMED SAFE END · VRAM 복구 · tail diff=%d/32',frames,bad))
  if bad==0 then emu.log('  ★ RAM TAIL PASS: $5E20-$5E3F를 한 바이트도 건드리지 않았다') end
  armed, vram_backup, tail_backup = false, nil, nil
end

emu.addEventCallback(function()
  frames=frames+1
  if not checked and stub_ok() then checked=true; emu.log('준비됨 -- 디스크 훅과 상주부 확인') end
  if inspect1>0 and frames>=inspect1 then inspect1=0; inspect(1) end
  if inspect2>0 and frames>=inspect2 then inspect2=0; inspect(2) end
  local s=emu.getState() or {}; local playing=s['cdrom.adpcm.playing']==true
  if playing and not was_playing then
    local ending=(((s['cdrom.adpcm.readAddress'] or 0)+(s['cdrom.adpcm.adpcmLength'] or 0))%0x10000)
    if s['cdrom.scsi.sector']==0x003078 and ending==0x6800 and
       (s['cdrom.adpcm.playbackRate'] or 0)==0x0E then stage() end
  elseif not playing and was_playing and armed then disarm() end
  was_playing=playing
end,emu.eventType.startFrame)

emu.log('PROBE_SUB_AC_TIMED_SAFE 0.4.1 loaded')
emu.log(string.format('  엔진 %d B · CPU $5B80-$%04X · 금지구간 $5E20부터',#engine,ENGINE_AT+#engine-1))
emu.log('  0.4.0 UI 복귀 실패의 $5E22-$5E3D 침범을 제거한 판')
