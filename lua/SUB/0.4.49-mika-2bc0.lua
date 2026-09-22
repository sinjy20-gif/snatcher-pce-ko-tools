-- SUB 0.4.49 -- 미카 3조각만 실측 생존 블록 $2BC0에 고정하는 시험판
-- Power Cycle 뒤 다른 SUB Lua를 끄고 이 파일 하나만 실행한다.

SUB_FRAGMENT_FORCE_KEY = '00D00E437790'
SUB_FRAGMENT_FORCE_BASE = 0x2BC0
dofile('C:/snatcher/lua/SUB/0.4.48-fragment-wipe.lua')
SUB_FRAGMENT_FORCE_KEY = nil
SUB_FRAGMENT_FORCE_BASE = nil

emu.log('SUB 0.4.49 loaded -- Mika 00D00E437790 all fragments forced to $2BC0')
