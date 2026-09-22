-- SUB 0.5.171 -- CD-DA 정지 신호 찾기
--
-- ★ 순수 관측.  아무것도 안 쓴다.  화면에도 아무것도 안 그린다.
--
-- 왜
-- --
-- 스케줄러는 elapsed 를 프레임마다 올릴 뿐 **트랙이 멈춘 걸 모른다.**
-- 그래서 오프닝을 스킵하면 (2026-09-04 실기):
--
--     첫 자막 전 스킵   ready=$FF 라 아무것도 안 그리고 STATE=2 에 갇힌다
--                       -> $5B80 을 안 돌려줘 게임이 검은 화면
--     첫 자막 후 스킵   구간이 계속 떠서 다음 화면에 자막이 얹힌다
--
-- 둘 다 "정지를 감지 못 한다" 하나가 원인이다.  STATE=3 을 앞당겨 쓸 신호가
-- 필요한데, 전례가 하나 있고 **폐기됐다**:
--
--     0.4.6.23  ($263C | $2638) == 0 이면 정지로 보고 복원
--     0.4.6.24  ★그건 지속 상태가 아니라 **1 프레임짜리 시작 펄스**였다
--
-- 그러니 이번엔 후보를 여러 개 동시에 재고, **재생 중 내내 유지되다가 멈출 때
-- 바뀌는** 값이 있는지 본다.  없으면 다른 방법을 찾아야 한다.
--
-- 무엇을 보나  (값이 바뀔 때만 기록한다)
-- ------------
--     $26F9   cdda_check 가 트랙 판정에 쓰는 값 (& $7F == $11 이면 트랙 17)
--     $263C   accepted/waiting
--     $2638   actual track playing
--     $20A2   현재 트랙 (BCD)
--     $20A7~9 절대 MSF (BCD).  트랙 시작에만 갱신된다고 알려져 있다
--     $7FDF   STATE
--     $180D   ADPCM playing bit (대조군)
--
-- 어떻게 쓰나
-- -----------
--   1  0.4.7.6 으로 오프닝을 튼다
--   2  자막이 몇 줄 지나가게 둔다      (재생 중 값이 어떤지 본다)
--   3  ★스킵한다
--   4  10 초쯤 더 둔다                 (멈춘 뒤 값이 어떤지 본다)
--   5  스크립트를 멈춘다               (요약이 찍힌다)
--
-- 판정
-- ----
--   재생 중 내내 한 값이고 스킵 뒤 달라지는 주소가 있으면 -> 그것이 정지 신호
--   전부 안 바뀌면 -> 이 주소들로는 못 잡는다.  다른 길을 찾아야 한다
--
-- 산출물  C:/snatcher/dump/cdda_stop_0_5_171_<시각>.tsv

local MEM = emu.memType.pceMemory

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/cdda_stop_0_5_171_' .. STAMP .. '.tsv'
local out   = assert(io.open(PATH, 'w'))
out:write('frame\tname\taddr\told\tnew\n')

local function say(m) emu.log(m); print(m) end

local WATCH = {
  { name = 'trk_26F9', addr = 0x26F9 },
  { name = 'acc_263C', addr = 0x263C },
  { name = 'ply_2638', addr = 0x2638 },
  { name = 'sq_trk',   addr = 0x20A2 },
  { name = 'sq_m',     addr = 0x20A7 },
  { name = 'sq_s',     addr = 0x20A8 },
  { name = 'sq_f',     addr = 0x20A9 },
  { name = 'STATE',    addr = 0x7FDF },
  { name = 'adpcm',    addr = 0x180D },
}

local frame = 0
local last = {}
local changes = {}
local rows = 0

-- 각 주소가 "어떤 값으로 얼마나 오래 있었나" 를 센다.
-- 재생 중 내내 한 값이면 그 값의 프레임 수가 크게 나온다.
local hold = {}

for _, w in ipairs(WATCH) do
  last[w.name] = -1
  changes[w.name] = 0
  hold[w.name] = {}
end

emu.addEventCallback(function()
  frame = frame + 1
  for _, w in ipairs(WATCH) do
    local v = emu.read(w.addr, MEM, false) or -1
    local prev = last[w.name]
    if v ~= prev then
      last[w.name] = v
      if prev ~= -1 then
        changes[w.name] = changes[w.name] + 1
        if rows < 600 then
          rows = rows + 1
          say(('f%-7d %-9s $%04X  $%02X -> $%02X')
                :format(frame, w.name, w.addr, prev, v))
          out:write(('%d\t%s\t%04X\t%02X\t%02X\n')
                      :format(frame, w.name, w.addr, prev, v))
          out:flush()
        end
      end
    end
    local t = hold[w.name]
    t[v] = (t[v] or 0) + 1
  end
  if frame % 600 == 0 then
    local parts = {}
    for _, w in ipairs(WATCH) do
      parts[#parts + 1] = ('%s=$%02X'):format(w.name, last[w.name])
    end
    say(('심박 f%-7d  %s'):format(frame, table.concat(parts, ' ')))
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  out:write('#\n# 주소별 값 체류 프레임 수 (많이 머문 값이 곧 "재생 중 상태")\n')
  say('')
  say('끝 -- 주소별 값 체류 (프레임 수)')
  for _, w in ipairs(WATCH) do
    local t = hold[w.name]
    local vals = {}
    for v, n in pairs(t) do vals[#vals + 1] = { v = v, n = n } end
    table.sort(vals, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#vals, 5) do
      parts[#parts + 1] = ('$%02X x%d'):format(vals[i].v, vals[i].n)
    end
    local line = ('  %-9s $%04X  변화 %-4d  %s')
                   :format(w.name, w.addr, changes[w.name],
                           table.concat(parts, ' · '))
    say(line)
    out:write('# ' .. line .. '\n')
  end
  out:close()
  say('')
  say('  읽는 법: 재생 중 내내 한 값이었다가 스킵 뒤 달라진 주소가 정지 신호다.')
  say('           변화 수가 0 이면 그 주소로는 못 잡는다.')
  say('  ' .. PATH)
end, emu.eventType.scriptEnded)

say('SUB 0.5.171-cdda-stop-signal armed -- 순수 관측')
say('  오프닝 재생 -> 자막 몇 줄 지나가게 두기 -> ★스킵 -> 10 초 더 두기 -> 스크립트 정지')
say('  ' .. PATH)
