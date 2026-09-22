-- LOAD_SUBTITLE_NATIVE 0.8.2 launcher
-- 비대상 AD_STAT에서 AC 레지스터를 건드리지 않는 gated BIOS만 허용한다.

local MEM=emu.memType.pceMemory
assert(emu.read(0xF61A,MEM)==0x20 and emu.read(0xF61B,MEM)==0xC4 and emu.read(0xF61C,MEM)==0xFE,
       '0.8.2 BIOS가 아니다: Syscard3_galmuri_sub_native_0_8_2.pce로 전원 재시작할 것')
assert(emu.read(0xF6EF,MEM)==0x20 and emu.read(0xF6F0,MEM)==0xE7 and emu.read(0xF6F1,MEM)==0xFE,
       '0.8.2 BIOS AD_STAT 훅이 아니다')
-- $FEE7: PHP/PHA, $FEE9: LDA $22A6. 구 0.8.1의 무조건 mailbox 호출을 거부한다.
assert(emu.read(0xFEE7,MEM)==0x08 and emu.read(0xFEE8,MEM)==0x48 and
       emu.read(0xFEE9,MEM)==0xAD and emu.read(0xFEEA,MEM)==0xA6 and
       emu.read(0xFEEB,MEM)==0x22,
       '0.8.2 gated AD_STAT 코드가 아니다 -- 구 0.8.1 BIOS 사용 금지')

emu.log('LOAD_SUBTITLE_NATIVE 0.8.2 launcher PASS · 비대상 AC 쓰기 차단 BIOS 확인')
dofile('C:/snatcher/lua/LOAD_SUBTITLE_NATIVE_0_8_1.lua')
