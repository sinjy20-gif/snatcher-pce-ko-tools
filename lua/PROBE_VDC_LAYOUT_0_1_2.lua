-- PROBE_VDC_LAYOUT 0.1.2
--
-- 0.1.1 의 결함 -- 한 순간만 찍었다
-- ---------------------------------
-- 0.1.1 은 60 프레임째에 딱 한 번 상태를 찍었고, 거기서
--
--     vdc.spritesEnabled  false
--
-- 가 나왔다.  그래서 "이 장면은 스프라이트를 안 쓴다" 고 판단했는데 **틀렸다.**
-- 소유자가 스프라이트 뷰어에서 미카의 눈과 길리언 초상화를 실제로 확인했다.
--
-- 원인은 표본 하나다.  startFrame 훅이 잡은 그 한 순간이 VBlank 였거나 장면
-- 전환 중이었을 수 있다.  같은 밤에 이미 한 번 밟은 함정이다 (VRAM 덤프 3 장을
-- 보고 $7B00 이 비었다고 판단했다가, 323 샘플 프로브가 반대를 말했다).
--
-- 그리고 8-19 문서가 이 지점을 경고해 두었다:
--     "SATB 자동탐지가 satbTransferNextWordCounter = 2 를 집어 $0002 를 읽었다"
--
-- 이 판이 하는 것
-- ---------------
-- 관심 키를 **매 프레임 누적**한다.  true/false 는 횟수를, 숫자는 값별 빈도를 센다.
-- 한 순간이 아니라 분포를 본다.
--
-- 출력  C:/snatcher/dump/probe_vdc_layout_0_1_2_<날짜>.tsv   (읽기만 한다)
--
-- 쓰는 법
--   음성 대사 장면을 몇 개 지나가고 정지한다.  10 초마다 중간 저장도 한다.

local WATCH = {
  'vdc.spritesEnabled', 'vdc.nextSpritesEnabled', 'vdc.bgEnabled',
  'vdc.satbBlockSrc', 'vdc.repeatSatbTransfer', 'vdc.satbTransferRunning',
  'vdc.satbTransferPending', 'vdc.hvReg.columnCount', 'vdc.hvReg.rowCount',
  'vdc.hvReg.spriteAccessMode',
}

local tally, frames = {}, 0
for _, k in ipairs(WATCH) do tally[k] = {} end

local function save()
  local name = string.format('C:/snatcher/dump/probe_vdc_layout_0_1_2_%s.tsv',
                             os.date('%Y%m%d_%H%M%S'))
  local f = io.open(name, 'w')
  if f == nil then emu.log('저장 실패: ' .. name) return end
  f:write('key\tvalue\tcount\tpercent\n')
  emu.log(string.format('--- %d 프레임 누적 ---', frames))
  for _, k in ipairs(WATCH) do
    local seen = tally[k]
    local vals = {}
    for v, _ in pairs(seen) do vals[#vals + 1] = v end
    table.sort(vals, function(a, b) return seen[a] > seen[b] end)
    local parts = {}
    for _, v in ipairs(vals) do
      local pct = 100 * seen[v] / math.max(1, frames)
      f:write(string.format('%s\t%s\t%d\t%.1f\n', k, v, seen[v], pct))
      parts[#parts + 1] = string.format('%s %.0f%%', v, pct)
    end
    if #parts > 0 then
      emu.log(string.format('  %-32s %s', k, table.concat(parts, ' · ')))
    end
  end
  f:close()
  emu.log('-> ' .. name)
end

emu.addEventCallback(function()
  frames = frames + 1
  local st = emu.getState()
  for _, k in ipairs(WATCH) do
    local v = st[k]
    if v ~= nil then
      local key = tostring(v)
      if type(v) == 'number' and v == math.floor(v) and v >= 0 then
        key = string.format('%d ($%X)', v, v)
      end
      tally[k][key] = (tally[k][key] or 0) + 1
    end
  end
  if frames % 600 == 0 then save() end
end, emu.eventType.startFrame)

emu.addEventCallback(save, emu.eventType.scriptEnded)

emu.log('PROBE_VDC_LAYOUT 0.1.2 loaded')
emu.log('  매 프레임 누적한다.  음성 대사 장면 몇 개 지나가고 정지할 것')
emu.log('  10 초마다 중간 저장도 한다')
