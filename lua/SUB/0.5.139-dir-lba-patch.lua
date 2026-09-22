-- SUB 0.5.139 -- 디렉터리 LBA 를 AC 에서 런타임에 고친다.  디스크 안 굽는다  ★개입판
--
-- ⚠ 개입판이다.  Arcade Card RAM 의 디렉터리를 고쳐 쓴다.  디스크는 안 건드린다.
--
-- 무엇을 증명하려는가
-- ---------------------------------------------------------------------------
-- 키 가운데가 FFFF 인 음성(8.19초·64KB 초과) 173 건만 자막이 안 뜬다.
-- `0.5.138` 이 디스크 읽기 명령을 직접 떠서 원인을 확정했다:
--
--     READ  LBA=003123  32 섹터   ->   PLAY (ADPCM_003143_FFFF_0E)
--     포화식  003143 - ceil(FFC3/2048) = 003143 - 32 = 003123   ✓ 오차 0
--
-- 그런데 디스크의 디렉터리에는 **003121** 이 실려 있다 (2 섹터 앞).
-- 빌더의 "포화 길이 보정" 이 실측 바이트로 되짚어 LBA 를 당겼기 때문이다.
--
--     ★ 디렉터리 LBA 는 adpcm_lba_master_index.bin 이 아니라
--       **adpcm_lba_all.tsv** 에서 온다 (build_adpcm_native_subtitle_table.py).
--       출하본은 그 둘이 서로 다른 판이었다 -- .bin 은 보정 끔, all.tsv 는 보정 켬
--
-- 이 판이 하는 일
-- ---------------------------------------------------------------------------
-- AC 의 디렉터리를 훑어 틀린 LBA 167 개를 맞는 값으로 **그 자리에서** 바꾼다.
-- 디스크를 다시 굽지 않고 가설을 끝까지 확인한다.
--
-- 판정
--     고친 뒤 FFFF 음성에 자막이 뜬다   -> 확정.  보정을 끄고 다시 구우면 173 건이 산다
--     안 뜬다                            -> LBA 는 원인이 아니다.  AC 슬롯을 봐야 한다
--     디렉터리를 못 찾는다               -> BASE 가 다르다.  아래 로그의 후보를 볼 것
--
-- ★ 되돌리려면 Power Cycle 하면 된다.  디스크는 그대로다.
--
-- 산출물  C:/snatcher/dump/dir_patch_0_5_139_<시각>.tsv

local BASE     = 0x1F2800     -- adpcm_native_subtitle_table.json 의 directory_base
local STRIDE   = 9            -- LBA u24 BE + payload ptr u24 LE + VRAM 즉치 3 B
local MAX_ENTS = 1200
local RECHECK  = 300          -- 이만큼 프레임마다 되돌아갔는지 다시 본다

-- 틀린 LBA -> 맞는 LBA  (보정 켬 -> 보정 끔.  모호한 쌍은 뺐다)
local FIX = {
  [0x003121] = 0x003123,
  [0x003242] = 0x003246,
  [0x003282] = 0x0032A4,
  [0x0032D9] = 0x0032F8,
  [0x00330A] = 0x003347,
  [0x0033AD] = 0x0033B7,
  [0x0033F0] = 0x003403,
  [0x0034AA] = 0x0034AB,
  [0x003520] = 0x00357E,
  [0x0035CE] = 0x0035FC,
  [0x003625] = 0x003657,
  [0x00367B] = 0x0036A9,
  [0x003703] = 0x00370B,
  [0x0037C1] = 0x0037C9,
  [0x003AD4] = 0x003AE2,
  [0x003B83] = 0x003B92,
  [0x003BE2] = 0x003BE3,
  [0x003C2E] = 0x003C57,
  [0x003D37] = 0x003D4A,
  [0x003D6D] = 0x003D7D,
  [0x003DAD] = 0x003DBA,
  [0x003E16] = 0x003E33,
  [0x003E80] = 0x003E84,
  [0x003EA4] = 0x003EA8,
  [0x003EC3] = 0x003ECC,
  [0x003F8B] = 0x003F9B,
  [0x0040F1] = 0x004107,
  [0x00449F] = 0x0044AC,
  [0x0045B5] = 0x0045C2,
  [0x004635] = 0x00463C,
  [0x0046FB] = 0x004708,
  [0x004882] = 0x004889,
  [0x00488D] = 0x0048B0,
  [0x0048F2] = 0x0048F3,
  [0x004CAA] = 0x004CCB,
  [0x004D0D] = 0x004D1F,
  [0x004D3F] = 0x004D51,
  [0x004DB6] = 0x004DCB,
  [0x0053E6] = 0x0053F4,
  [0x005430] = 0x00543B,
  [0x0054C2] = 0x0054C9,
  [0x005507] = 0x00550A,
  [0x0055FA] = 0x005603,
  [0x0057B7] = 0x0057CC,
  [0x00581E] = 0x005821,
  [0x005A9A] = 0x005A9B,
  [0x005ACF] = 0x005AD2,
  [0x005AFD] = 0x005B12,
  [0x005CA8] = 0x005CB5,
  [0x005D39] = 0x005D3D,
  [0x005D8B] = 0x005D8F,
  [0x005DAE] = 0x005DBC,
  [0x005E74] = 0x005E81,
  [0x005EA5] = 0x005EAE,
  [0x005EA7] = 0x005ED7,
  [0x005F55] = 0x005F57,
  [0x005FA6] = 0x005FB0,
  [0x005FC4] = 0x005FF0,
  [0x006027] = 0x00603C,
  [0x006064] = 0x006071,
  [0x0060A9] = 0x0060B2,
  [0x006127] = 0x00612F,
  [0x006199] = 0x0061A2,
  [0x006231] = 0x00623C,
  [0x0062A8] = 0x0062A9,
  [0x0063A0] = 0x0063A4,
  [0x00640F] = 0x006415,
  [0x0064AA] = 0x0064B8,
  [0x0064FC] = 0x006501,
  [0x0065F6] = 0x00660E,
  [0x006676] = 0x00667E,
  [0x006C77] = 0x006C80,
  [0x006E2A] = 0x006E2B,
  [0x006E88] = 0x006E92,
  [0x006F04] = 0x006F0B,
  [0x006F7C] = 0x006F7D,
  [0x006FF4] = 0x006FF9,
  [0x007046] = 0x007047,
  [0x007130] = 0x007142,
  [0x007239] = 0x007245,
  [0x007375] = 0x007378,
  [0x007410] = 0x007433,
  [0x0074B8] = 0x0074BB,
  [0x0074DF] = 0x0074EC,
  [0x00751E] = 0x007523,
  [0x007564] = 0x00756D,
  [0x007600] = 0x007604,
  [0x007680] = 0x007682,
  [0x007795] = 0x007798,
  [0x0077D9] = 0x0077DA,
  [0x00780E] = 0x00780F,
  [0x00788B] = 0x007893,
  [0x0078F0] = 0x007908,
  [0x007933] = 0x007940,
  [0x00795C] = 0x00796D,
  [0x0079B8] = 0x0079C9,
  [0x0079F7] = 0x0079FA,
  [0x007A10] = 0x007A1D,
  [0x007A4C] = 0x007A4E,
  [0x007A76] = 0x007A9E,
  [0x007B00] = 0x007B04,
  [0x007B38] = 0x007B3E,
  [0x007E78] = 0x007E7D,
  [0x007F7A] = 0x007F9F,
  [0x008072] = 0x008085,
  [0x008083] = 0x0080B8,
  [0x0080F9] = 0x00810D,
  [0x008130] = 0x008141,
  [0x008135] = 0x008175,
  [0x0081D4] = 0x0081D5,
  [0x0081EC] = 0x0081F6,
  [0x008233] = 0x008234,
  [0x00826D] = 0x008272,
  [0x008285] = 0x00829B,
  [0x0082DD] = 0x0082DF,
  [0x0082F3] = 0x008301,
  [0x00830E] = 0x00832F,
  [0x008354] = 0x008387,
  [0x0083CF] = 0x0083DA,
  [0x0083FB] = 0x008405,
  [0x008430] = 0x008456,
  [0x00846C] = 0x00849C,
  [0x0084D1] = 0x0084EC,
  [0x0084FD] = 0x008527,
  [0x00855F] = 0x008571,
  [0x0085A3] = 0x0085AC,
  [0x0085F6] = 0x008609,
  [0x008613] = 0x00863C,
  [0x00868A] = 0x0086A6,
  [0x00870F] = 0x008710,
  [0x008715] = 0x008731,
  [0x00876A] = 0x00876D,
  [0x00876D] = 0x008790,
  [0x0087BC] = 0x0087DA,
  [0x008802] = 0x008818,
  [0x00882F] = 0x00884E,
  [0x0088B5] = 0x0088B6,
  [0x0088C9] = 0x0088D7,
  [0x0088D6] = 0x008905,
  [0x00894F] = 0x008954,
  [0x0089A0] = 0x0089A5,
  [0x0089CC] = 0x0089D6,
  [0x008A5F] = 0x008A6E,
  [0x008A99] = 0x008AA7,
  [0x008AB1] = 0x008AD5,
  [0x008B3F] = 0x008B53,
  [0x008B69] = 0x008B87,
  [0x008BC1] = 0x008BD1,
  [0x008BE8] = 0x008C01,
  [0x008C24] = 0x008C3A,
  [0x008C6E] = 0x008C85,
  [0x008CB0] = 0x008CBC,
  [0x008D15] = 0x008D2D,
  [0x008D83] = 0x008D85,
  [0x008D90] = 0x008DA7,
  [0x008D95] = 0x008DDE,
  [0x008E2E] = 0x008E47,
  [0x008E72] = 0x008E80,
  [0x008E9B] = 0x008EB2,
  [0x008EDE] = 0x008EE9,
  [0x008F04] = 0x008F21,
  [0x008F58] = 0x008F5E,
  [0x008F82] = 0x008F84,
  [0x008FAE] = 0x008FB5,
  [0x008FC6] = 0x008FF3,
  [0x0090AA] = 0x0090B1,
  [0x0090DF] = 0x0090E0,
}

local STAMP = os.date('%Y%m%d_%H%M%S')
local PATH  = 'C:/snatcher/dump/dir_patch_0_5_139_' .. STAMP .. '.tsv'
local AC = emu.memType.pceArcadeCardRam

local out = io.open(PATH, 'w')
out:write('slot\taddr\twas\tnow\tnote\n')
local function say(m) emu.log(m); print(m) end
local function rd(a) local ok, v = pcall(emu.read, a, AC); return ok and v or -1 end
local function wr(a, v) pcall(emu.write, a, v, AC) end
local function lbaAt(a)
  local b0, b1, b2 = rd(a), rd(a+1), rd(a+2)
  if b0 < 0 or b1 < 0 or b2 < 0 then return -1 end
  return (b0 << 16) | (b1 << 8) | b2
end

-- 디렉터리가 정말 거기 있는지 먼저 본다 -- 오름차순 · 그럴듯한 범위
local function looksLikeDir(base)
  local prev, n = -1, 0
  for i = 0, 15 do
    local v = lbaAt(base + i * STRIDE)
    if v < 0x001000 or v > 0xFFFFFF or v <= prev then return false end
    prev, n = v, n + 1
  end
  return n == 16
end

local function countEntries(base)
  local prev, n = -1, 0
  while n < MAX_ENTS do
    local v = lbaAt(base + n * STRIDE)
    if v < 0x001000 or v > 0xFFFFFF or v <= prev then break end
    prev, n = v, n + 1
  end
  return n
end

local dirBase, nEnt = nil, 0
if looksLikeDir(BASE) then dirBase = BASE end
if not dirBase then
  say('★ BASE 에 디렉터리가 없다.  AC 를 훑어 후보를 찾는다...')
  for a = 0x100000, 0x1FF000, 0x100 do
    if looksLikeDir(a) then dirBase = a; say(('   후보 발견 $%06X'):format(a)); break end
  end
end

local patched, missing = 0, 0
local function applyPatch(first)
  if not dirBase then return end
  local hit = 0
  for i = 0, nEnt - 1 do
    local at = dirBase + i * STRIDE
    local v  = lbaAt(at)
    local to = FIX[v]
    if to then
      wr(at,     (to >> 16) & 0xFF)
      wr(at + 1, (to >> 8)  & 0xFF)
      wr(at + 2,  to        & 0xFF)
      hit = hit + 1
      if first then
        out:write(('%d\t%06X\t%06X\t%06X\t고침\n'):format(i, at, v, to))
      end
    end
  end
  if first then patched = hit end
  return hit
end

if dirBase then
  nEnt = countEntries(dirBase)
  say(('디렉터리 $%06X · 항목 %d 개'):format(dirBase, nEnt))
  local before = lbaAt(dirBase)
  say(('  첫 항목 LBA %06X · 마지막 %06X'):format(before, lbaAt(dirBase + (nEnt-1)*STRIDE)))
  applyPatch(true)
  say(('★ 고친 항목 %d 개 / 표에 있는 %d 쌍'):format(patched, 167))
  if patched == 0 then
    say('  ⚠ 하나도 안 맞았다.  디렉터리가 이미 맞는 값이거나 다른 세대다')
  end
  out:flush()
else
  say('⚠ 디렉터리를 못 찾았다.  BASE 를 확인할 것')
end

local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if dirBase and frame % RECHECK == 0 then
    local again = applyPatch(false)
    if again > 0 then
      say(('  (되돌아가 있어 %d 개 다시 고침 -- f%d)'):format(again, frame))
      out:write(('-1\t0\t0\t0\tf%d 재적용 %d 개\n'):format(frame, again))
      out:flush()
    end
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function() out:close() end, emu.eventType.scriptEnded)
say('SUB 0.5.139-dir-lba-patch armed')
say('  ★ 이제 FFFF 음성(국장실 긴 대사)을 들어보라.  자막이 뜨면 확정이다')
say('  ' .. PATH)
