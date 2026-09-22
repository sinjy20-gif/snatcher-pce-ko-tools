-- SUB 0.3.13 -- 0.4.6.2 one-shot preload + BIOS work-ZP restore audit
SUB_AUDIT_VERSION = '0.3.13 / build 0.4.6.2'
SUB_PRELOAD_ENTER = 0xFFAB
SUB_BOOT_DONE = 0xFFA6
dofile('C:/snatcher/lua/SUB/0.3.12.lua')
SUB_AUDIT_VERSION, SUB_PRELOAD_ENTER, SUB_BOOT_DONE = nil, nil, nil
