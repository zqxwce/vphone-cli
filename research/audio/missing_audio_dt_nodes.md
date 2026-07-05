# Missing audio DeviceTree nodes — iPhone17,3 (d47ap) not in VM (vresearch101ap+patches)
# 107 nodes. Generated for duplication reference.

## /arm-io/aop
    compatible = "iop,ascwrap-v6"
    iommu-parent = "H"
    interrupt-parent = " "
    interrupts = <16B 0x87010000860100008901000088010000>
    ext-irq-reg-index = u32=4 (0x04000000)
    clock-gates = <0B 0x>
    clock-ids = <0B 0x>
    reg = <80B 0x00006000010000000080080000000000000005000100000000400000000000000000c0000100000000001e000000000000802af800000000080000000000000000c062000100000008c0030000000000>
    iop-version = u32=1 (0x01000000)
    device_type = "aop"
    AAPL,phandle = "."
    power-gates = <0B 0x>
    role = "AOP"

## /arm-io/aop/iop-aop-nub
    aop-target = u32=1 (0x01000000)
    sleep-on-hibernate = <0B 0x>
    k2-int-opendrain = <0B 0x>
    compatible = "iop-nub,rtbuddy-v2"
    coredump-enable = "@"
    routes = "Q"
    region-base = u64=0x0000c01003000000
    firmware-name = "d4yaop"
    AAPL,phandle = "/"
    no-shutdown = u32=1 (0x01000000)
    has-baseband = <0B 0x>
    region-size = u64=0x0000190000000000
    aop-fr-timebase = u32=1 (0x01000000)
    claim-wake = <0B 0x>
    watchdog-enable = <0B 0x>
    k2-pkg-id = <0B 0x>
    aop-isp-v2protocol = <0B 0x>

## /arm-io/aop/iop-aop-nub/aop-pio-filters
    pio-src-filt-global = u32=10 (0x0a000000)
    AAPL,phandle = "0"
    pio-dst-filt-global = u32=0 (0x00000000)
    pio-dst-filt-fr-global = u32=4106 (0x0a100000)

## /arm-io/aop/iop-aop-nub/aop-scm-xbar-d4y
    gpio-to-scm-muxsel = <84B 0x8400000000000000000000000c000000000000000400000030000000000000000f000000640000000000000003000000c8000000000000000c000000d4000000000000000b00000038000000000000000d000000>
    scm-to-gpio-muxsel = <24B 0x040000000000000020000000280000000000000033000000>
    gpio-to-scm-muxsel-por = <12B 0x280000000000000002000000>
    gpio-to-scm-muxsel-p1 = <12B 0x140000000000000002000000>
    AAPL,phandle = "1"

## /arm-io/aop/iop-aop-nub/aop-gapf-filters
    fabric-slices = <352B 0x1f000000000000000000741303000000ffbf75130300000001000000000000001f0000000000000050c270130300000053c270130300000001000000000000001f0000000000000050c870130300000053c870130300000001000000000000001f0000000000000050d870130300000053d870130300000001000000000000001f000000000000005098701303000000539870130300000001000000000000001f000000000000000000831003000000ff3f83100300000001000000000000001f000000000000000040871003000000ff7f87100300000001000000000000001f000000000000000000851003000000ff3f85100300000001000000000000001f000000000000000000841003000000ff3f84100300000001000000000000001f0000000000000000c0851003000000ffff85100300000001000000000000001f0000000000000000c0841003000000ffff8410030000000100000000000000>
    AAPL,phandle = "2"
    fabric-slice-fmt-ver = u32=1 (0x01000000)
    sram-ut-agents-count = u32=3 (0x03000000)
    sram-ut-agents = <24B 0x98980100ff0ffcff97980100ff0ffcff99980100ff0ffcff>
    device_type = "aop-gapf-filters"
    sram-t-agents = <32B 0x95980100ff0ffcff96980100ff0ffcff9a980100ff0ffcff82980100ff0ffcff>
    sram-t-agents-count = u32=4 (0x04000000)

## /arm-io/aop/iop-aop-nub/accel
    accel-offset-cal = "syscfg/AROC"
    low-temp-accel-offset = "syscfg/LTAO"
    device-usage-page = u32=65280 (0x00ff0000)
    AAPL,phandle = "3"
    device_type = "accel"
    accel-range-sensitivity-cal = "syscfg/ARSC"
    device-usage = u32=3 (0x03000000)
    accel-sensitivity-calibration = "syscfg/ASCl"
    accel-nominal-extr-cal = "syscfg/ARXN,hex/020001010000000028000000010000000000FFFF0000000000000000000000000000FFFF0000000000000000000000000000FFFF82B507B9"
    accel-interrupt-calibration = "syscfg/AICl"
    accel-orientation = "syscfg/ARot"
    accel-range-intr-cal = "syscfg/ARNC,hex/03000101000000002C000000020000002000000000007A3F00000000000000000000000000007A3F00000000000000000000000000007A3F5CCD7FA3"
    accel-range-extr-cal = "syscfg/ARXC"

## /arm-io/aop/iop-aop-nub/hgaccel
    AAPL,phandle = "4"
    device-usage = u32=30 (0x1e000000)
    accel-nominal-extr-cal = "syscfg/AhXN,hex/010001010000000028000000010000000000FFFF0000000000000000000000000000FFFF0000000000000000000000000000FFFF95B15203"
    accel-range-intr-cal = <60B 0x02000101000000002c000000010000000001000000d0070000000000000000000000000000d0070000000000000000000000000000d0070000000000>
    device_type = "hgaccel"
    device-usage-page = u32=65280 (0x00ff0000)

## /arm-io/aop/iop-aop-nub/gyro
    gyro-interrupt-calibration = "syscfg/GICl"
    device-usage-page = u32=65280 (0x00ff0000)
    AAPL,phandle = "5"
    device_type = "gyro"
    gyro-range-extr-cal = "syscfg/GRXC"
    device-usage = u32=9 (0x09000000)
    gyro-nominal-extr-cal = "syscfg/GRXN,hex/020001010000000028000000010000000000010000000000000000000000000000000100000000000000000000000000000001004F5F34A6"
    gyro-range-intr-cal = "syscfg/GRNC,hex/03000101000000002C00000002000000A00F00000000FA390000000000000000000000000000FA390000000000000000000000000000FA39B96DC7D9"
    gyro-range-sensitivity-cal = "syscfg/GRSC"
    gyro-sensitivity-calibration = "syscfg/GSCl"
    gyro-temp-table = "syscfg/GYTT"
    gyro-orientation = "syscfg/GRot"

## /arm-io/aop/iop-aop-nub/compass
    compass-apl-compensation-boe = "syscfg/MDCC,hex/0100000061000000F80000004FFFFFFF"
    compass-apl-compensation-sdc = "syscfg/MDCC,hex/0100000061000000210100004FFFFFFF"
    device-usage = u32=10 (0x0a000000)
    compass-wallet-compensation = <40B 0x01000000ee2a010009cbffff3801000063ceffff4ed2000016020000ca170000eb430000b1f90000>
    compass-orientation = "syscfg/CRot,hex/010001010000000028000000030000000000FFFF000000000000000000000000000001000000000000000000000000000000FFFF54C53EE0"
    device_type = "compass"
    compass-vbus-compensation = "syscfg/CVCC,hex/010000005E000000E2000000EEFFFFFF"
    AAPL,phandle = "6"
    compass-hilo-compensation = "syscfg/CDCC"
    sysconfig-location-id-override = u32=0 (0x00000000)
    coex0-payload-off = u32=0 (0x00000000)
    device-usage-page = u32=65280 (0x00ff0000)
    coex0-notif-off = u32=3825172744 (0x0881ffe3)
    charger-compensation-vers = u32=2 (0x02000000)
    coex0-notif-on = u32=3825172743 (0x0781ffe3)
    enable-coex0 = <0B 0x>
    compass-mode-offset-comp = "syscfg/CMOC"
    compass-sens-calibration = "syscfg/CSCM"
    coex0-payload-on = u32=1 (0x01000000)
    compass-temp-calibration = <32B 0x030000008c0a00000000000000000000c8ffffff000000000000000000001400>
    compass-calibration = "syscfg/CPAS"
    coex0-driver-name = "IOPAudioSpeaker"
    coex0-prop = "Y"

## /arm-io/aop/iop-aop-nub/compass_1
    sysconfig-location-id-override = u32=1 (0x01000000)
    device-usage = u32=10 (0x0a000000)
    compass-orientation = "syscfg/JRot,hex/010001010100000028000000030000000000010000000000000000000000000000000100000000000000000000000000000001004b9528a4"
    AAPL,phandle = "7"
    compass-calibration = "syscfg/CPAS"
    device_type = "compass_1"
    device-usage-page = u32=65280 (0x00ff0000)

## /arm-io/aop/iop-aop-nub/pressure
    AAPL,phandle = "8"
    device-usage = "1"
    pressure-heater-resistance = u32=87000 (0xd8530100)
    pressure-global-offset-cal = "#"
    temp-compensation-table = "syscfg/PRTT"
    device_type = "pressure"
    pressure-offset-calibration = "syscfg/SPPO"
    device-usage-page = u32=20 (0x14000000)

## /arm-io/aop/iop-aop-nub/spherecontrol
    AAPL,phandle = "9"
    isp-aop-motion_full_rate-config = <16B 0x0080641003000000100000003c000000>
    isp-aop-control-config = <16B 0x0080641003000000400000003e000000>
    isp-aop-pearl-config = <16B 0x0080641003000000200000003d000000>
    device_type = "spherecontrol"
    isp-aop-motion-config = <16B 0x0080641003000000800000003f000000>

## /arm-io/aop/iop-aop-nub/prox
    device-usage = u32=8 (0x08000000)
    function-saca = <12B 0x6801000041434153786f7270>
    prox-calibration = "syscfg/PxCl"
    device_type = "prox"
    AAPL,phandle = ":"
    device-usage-page = u32=65280 (0x00ff0000)

## /arm-io/aop/iop-aop-nub/SPUApp
    AAPL,phandle = ";"
    spkamp-config_btmspk = <16B 0x05060002fd0008f0e84000013a010001>
    spkamp-names = ["arc", "btmspk"]
    spkamp-config_arc = <16B 0x02030a02fd0008f0e843000130010101>
    device_type = "SPUApp"

## /arm-io/aop/iop-aop-nub/aop-audio
    AAPL,phandle = "<"
    compatible = "iop-audio,aop-service"
    device_type = "aop-audio"

## /arm-io/aop/iop-aop-nub/aop-voicetrigger
    AAPL,phandle = "="
    name-override = "AOPVoiceTriggerService"
    compatible = "iop-audio,aop-service"
    device_type = "aop-voicetrigger"

## /arm-io/aop/iop-aop-nub/smc-control
    AAPL,phandle = ">"
    smc-aop-charge-config = <16B 0x0000641003000000040000002a000000>
    device_type = "smc-control"

## /arm-io/aop/iop-aop-nub/aop-smart-cover
    device_type = "aop-smart-cover"
    AAPL,phandle = "?"

## /arm-io/aop/iop-aop-nub/rose
    sequence-power_off = <46B 0x66756e6374696f6e2d726f73655f7265736574000090010066756e6374696f6e2d726f73655f70777200000a0000>
    iommu-parent = "P"
    AAPL,phandle = "@"
    function-rose_pwr = <20B 0x7700000038574b70444c63700000000000000800>
    sequence-power_on = <22B 0x66756e6374696f6e2d726f73655f7077720001640000>
    device_type = "rose"
    function-rose_reset = <20B 0x7700000038574b704f4963700000800000000700>
    sequence-trigger_coredump = <54B 0x66756e6374696f6e2d726f73655f636f726564756d70000114000066756e6374696f6e2d726f73655f636f726564756d700000010000>
    function-rd_rose_pwr = <20B 0x7700000038524b70444c63700000000000000800>
    function-rose_coredump = <16B 0x590000004f4950470900000001010000>
    sequence-reset = <48B 0x66756e6374696f6e2d726f73655f726573657400000a000066756e6374696f6e2d726f73655f726573657400010a0000>

## /arm-io/aop/iop-aop-nub/jarvis
    std-dev-z-cal = "0"
    phi-attach-high-cal = u32=4294816564 (0x34b3fdff)
    phi-ignore-low-cal = u32=45875 (0x33b30000)
    AAPL,phandle = "A"
    theta-detach-low-cal = u32=35389 (0x3d8a0000)
    phi-attach-low-cal = u32=105512 (0x289c0100)
    phi-ignore-high-cal = u32=159907 (0xa3700200)
    phi-detach-high-cal = u32=55050 (0x0ad70000)
    std-dev-y-cal = "T"
    device_type = "jarvis"
    magnitude-cal = u32=89784320 (0x00005a05)
    theta-attach-low-cal = u32=0 (0x00000000)
    theta-detach-high-cal = u32=205783 (0xd7230300)
    phi-detach-low-cal = u32=4294866371 (0xc375feff)
    std-dev-x-cal = "g"
    theta-attach-high-cal = u32=170393 (0x99990200)

## /arm-io/aop/iop-aop-nub/als
    ce-model = u32=3 (0x03000000)
    tint-time-sync = u32=24 (0x18000000)
    tint-time-async = u32=5 (0x05000000)
    sync2-1p2v-en = u32=1 (0x01000000)
    hotspot-center-y = u32=67062988 (0xcc4cff03)
    clk-freq-async = u32=32768 (0x00800000)
    supports-float-lux = u32=1 (0x01000000)
    AAPL,phandle = "B"
    device_type = "als"
    build-phase = "syscfg/CFG#"
    sync2-lower-freq-range-en = u32=1 (0x01000000)
    freq = "<"
    clk-freq-sync = u32=157440 (0x00670200)
    hotspot-center-x = u32=175472640 (0x0080750a)
    ce-threshold = "ff"

## /arm-io/aop/iop-aop-nub/gnss
    function-gnss-time-mark = <16B 0x590000004f4950470000000001010000>
    AAPL,phandle = "C"
    ap-time-mark-with-boot-arg = <0B 0x>
    device_type = "gnss"

## /arm-io/aop/iop-aop-nub/dcp-control
    device_type = "dcp-control"
    AAPL,phandle = "D"

## /arm-io/aop/iop-aop-nub/grimaldi-control
    function-flicker_bias = u64=0x9000000073626c66
    AAPL,phandle = "E"
    device_type = "grimaldi-control"

## /arm-io/aop/iop-aop-nub/cma
    coex0-payload-off = u32=0 (0x00000000)
    enable-coex0 = <0B 0x>
    AAPL,phandle = "F"
    coex0-driver-name = "IOPHaptics"
    coex0-notif-on = u32=3825172749 (0x0d81ffe3)
    coex0-prop = u32=219 (0xdb000000)
    device_type = "cma"
    coex0-payload-on = u32=1 (0x01000000)
    coex0-notif-off = u32=3825172750 (0x0e81ffe3)

## /arm-io/dart-aop
    vm-size-16 = " "
    vm-size-17 = " "
    allow-dram-apf-slices-0 = u32=0 (0x00000000)
    vm-size-1 = " "
    AAPL,phandle = "G"
    instance = ["TRAD", "DART"]
    vm-size-9 = u64=0x0000ffff00000000
    dart-options = "e"
    vm-base-1 = u64=0x0000000000020000
    vm-base-9 = u64=0x0000004000010000
    interrupt-parent = " "
    always-on = <0B 0x>
    bypass-12 = <0B 0x>
    sid = <24B 0x0c000000000000001000000003000000080000000a000000>
    compatible = "dart,t8110"
    page-size = "@"
    interrupts = u32=428 (0xac010000)
    exclave-sid = <16B 0x01000000110000000b00000009000000>
    manual-availability = u32=1 (0x01000000)
    retention = <0B 0x>
    vm-base-11 = u64=0x0000004000010000
    vm-base = u64=0x0000000000010000
    vm-base-16 = u64=0x0000004000010000
    sid-count = u32=18 (0x12000000)
    vm-base-0 = u64=0x0000004000010000
    vm-base-17 = u64=0x0000000000020000
    vm-size-0 = " "
    device_type = "dart"
    vm-size-11 = u64=0x0000ffff00000000
    reg = <16B 0x0000fc000100000000c0000000000000>
    vm-size = u64=0x0000000000030000

## /arm-io/dart-aop/mapper-aop
    AAPL,phandle = "H"
    reg = u32=0 (0x00000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-exclave-aop
    AAPL,phandle = "I"
    reg = u32=1 (0x01000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-aop2
    AAPL,phandle = "J"
    reg = u32=16 (0x10000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-exclave-aop2
    AAPL,phandle = "K"
    reg = u32=17 (0x11000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-admac-leap-s
    AAPL,phandle = "L"
    reg = u32=11 (0x0b000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-admac-base-ns
    device_type = "dart-mapper"
    reg = u32=8 (0x08000000)
    AAPL,phandle = "M"
    compatible = "iommu-mapper"
    allow-subpage-mapping = <0B 0x>

## /arm-io/dart-aop/mapper-admac-leap-ns
    device_type = "dart-mapper"
    reg = u32=10 (0x0a000000)
    AAPL,phandle = "N"
    compatible = "iommu-mapper"
    allow-subpage-mapping = <0B 0x>

## /arm-io/dart-aop/mapper-admac-base-s
    AAPL,phandle = "O"
    reg = u32=9 (0x09000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/dart-aop/mapper-scm
    AAPL,phandle = "P"
    reg = u32=3 (0x03000000)
    compatible = "iommu-mapper"
    device_type = "dart-mapper"

## /arm-io/aop-exclave-mailbox
    compatible = "iop,secure-rtbuddy-proxy"
    iommu-parent = "I"
    interrupt-parent = " "
    interrupts = u64=0x8d0100008a010000
    reg = <16B 0x00c06750030000000040000000000000>
    AAPL,phandle = "Q"
    exclave-assigned = <0B 0x>
    exclave-service = "com.apple.service.SecureRTBuddyAOP"
    claim-wake = <0B 0x>
    exclave-edk-service = "com.apple.service.SecureRTBuddyAOP_EDK"
    role = "AOP-EXCLAVE"

## /arm-io/aop-exclave-ioreporting
    interrupt-parent = " "
    exclave-assigned = <0B 0x>
    compatible = "iop,secure-rtbuddy-ioreporting"
    exclave-endpoint = "M"
    role = "AOP-EXCLAVE"
    AAPL,phandle = "R"

## /arm-io/aop-smbox
    mbox-index = u32=3 (0x03000000)
    AAPL,phandle = "S"

## /arm-io/aop2-smbox
    mbox-index = u32=3 (0x03000000)
    AAPL,phandle = "T"

## /arm-io/aop2
    compatible = "iop,ascwrap-v6"
    iommu-parent = "J"
    interrupt-parent = " "
    interrupts = <16B 0x8f0100008e0100009101000090010000>
    clock-gates = <0B 0x>
    clock-ids = <0B 0x>
    reg = <48B 0x000060010100000000800800000000000000050101000000004000000000000000c062010100000008c0030000000000>
    AAPL,phandle = "U"
    iop-version = u32=1 (0x01000000)
    device_type = "aop2"
    idle-ctrl-check = <0B 0x>
    power-gates = <0B 0x>
    role = "AOP2"

## /arm-io/aop2/iop-aop2-nub
    routes = "W"
    compatible = "iop-nub,rtbuddy-v2"
    sleep-on-hibernate = <0B 0x>
    AAPL,phandle = "V"
    watchdog-enable = <0B 0x>
    no-firmware-service = <0B 0x>
    no-shutdown = u32=1 (0x01000000)
    claim-wake = <0B 0x>
    aot-power = u32=1 (0x01000000)

## /arm-io/aop2-exclave-mailbox
    compatible = "iop,secure-rtbuddy-proxy"
    iommu-parent = "K"
    interrupt-parent = " "
    interrupts = u64=0x9501000092010000
    reg = <16B 0x00c06751030000000040000000000000>
    AAPL,phandle = "W"
    exclave-assigned = <0B 0x>
    exclave-service = "com.apple.service.SecureRTBuddyAOP2"
    claim-wake-endpoint-flags = <16B 0x30000000040000003100000004000000>
    claim-wake = <0B 0x>
    exclave-edk-service = "com.apple.service.SecureRTBuddyAOP2_EDK"
    role = "AOP2-EXCLAVE"

## /arm-io/aop2-exclave-ioreporting
    AAPL,phandle = "X"

## /arm-io/aop-gpio
    #interrupt-cells = u32=2 (0x02000000)
    interrupt-controller = <0B 0x>
    compatible = "gpio,t8101"
    interrupt-parent = " "
    interrupts = <28B 0x7c0100007d0100007e0100007f010000800100008101000082010000>
    #gpio-int-groups = u32=7 (0x07000000)
    no-resume-restore = u32=1 (0x01000000)
    reg = <16B 0x00408200010000000040000000000000>
    #gpio-pins = "9"
    device_type = "interrupt-controller"
    supported-int-groups = <12B 0x040000000500000006000000>
    wake-events = <0B 0x>
    wake-no-interrupt-group = u32=4 (0x04000000)
    #address-cells = u32=0 (0x00000000)
    AAPL,phandle = "Y"
    role = "AOP"

## /arm-io/sio
    map-range = <20B 0x4353494d00000085030000000040000000000000>
    compatible = "iop,ascwrap-v6"
    iommu-parent = "p"
    interrupt-parent = " "
    interrupts = <16B 0x65040000640400006704000066040000>
    clock-gates = u32=288 (0x20010000)
    clock-ids = <12B 0x890100008701000088010000>
    reg = <32B 0x0000e07501000000008008000000000000008575010000000040000000000000>
    device-type = <36B 0x495053640400000000000000524155640600000000000000415044640200000000000000>
    iop-version = u32=1 (0x01000000)
    device_type = "sio"
    AAPL,phandle = "l"
    dmashim = <108B 0x49505353000010850300000000001000000000000d0000000e0000000f0000000040000052415553000020850300000000001000000000000100000002000000030000000040000044554153000000860300000000001000000000001e0000001f0000002000000000100000>
    power-gates = u32=288 (0x20010000)
    role = "SIO"

## /arm-io/sio/iop-sio-nub
    coredump-enable = "@"
    no-firmware-service = <0B 0x>
    user-power-managed = u32=1 (0x01000000)
    compatible = "iop-nub,rtbuddy-v2"
    AAPL,phandle = "m"

## /arm-io/sio/iop-sio-nub/sio-dma
    AAPL,phandle = "n"
    compatible = "sio-dma-controller"
    device_type = "sio-dma"

## /arm-io/dart-sio
    flush-by-dva = u32=1 (0x01000000)
    compatible = "dart,t8110"
    page-size = "@"
    interrupt-parent = " "
    interrupts = u32=1120 (0x60040000)
    reg = <16B 0x00000675010000000000020000000000>
    sid-count = u32=16 (0x10000000)
    AAPL,phandle = "o"
    device_type = "dart"
    sid = u64=0x0000000001000000
    dart-options = "%"
    vm-base = u64=0x0000000000010000
    instance = ["TRAD", "DART"]
    vm-size = u64=0x0000000000030000

## /arm-io/dart-sio/mapper-sio
    device_type = "dart-mapper"
    reg = u32=0 (0x00000000)
    AAPL,phandle = "p"
    compatible = "iommu-mapper"
    allow-subpage-mapping = <0B 0x>

## /arm-io/dart-sio/mapper-aes
    device_type = "dart-mapper"
    reg = u32=1 (0x01000000)
    AAPL,phandle = "q"
    compatible = "iommu-mapper"
    allow-subpage-mapping = <0B 0x>

## /arm-io/smc/iop-smc-nub/smc-aop
    function-link-data_param_set = [">", "Stad"]
    device_type = "smc-aop"
    function-link-data_enable = [">", "lbne"]
    function-link-data_param_get = [">", "Gtad"]
    AAPL,phandle = "z"
    link-tx_config = <20B 0x0000640c03000000200000002d00000000100000>

## /arm-io/mtp-aop-mux
    AAPL,phandle = u32=140 (0x8c000000)
    compatible = "hid-transport,mux"
    device_type = "mtp-aop-mux"

## /arm-io/i2c2/audio-codec
    private = "1"
    samplerate-default = u64=0x0000000080bb0000
    function-Flicker_master = <12B 0x1b0100003144554166327061>
    interrupt-parent = "'"
    TempSensor = u64=0x0201060100000000
    smic-mic = u64=0x0208020803000000
    AOP = u64=0x0001000400000000
    Hall = u64=0x0201040200000000
    ASP1 = u64=0x1016070707820000
    interrupts = u64=0x8400000001000000
    int-id = u64=0x0404040404080800
    adc-gains = <12B 0x060606068383068686860000>
    flicker-config = u32=3 (0x03000000)
    function-pdm_rx_control = u64=0x25010000694d4450
    HPMic = u64=0x0101000400000000
    ASP2 = u64=0x1848000007010000
    fmic-mic = u64=0x0309020903000000
    AAPL,phandle = u32=144 (0x90000000)
    function-Receiver_master = <12B 0x190100003144554172327061>
    LPMic = u64=0x0001000400000000
    int-offset = u64=0x0002090b0d000100
    Receiver = u64=0x0100000100000000
    function-reset = <16B 0x590000004f4950470700000001000100>
    compatible = "audio-control,cs42l79"
    Flicker = u64=0x0201070200000000
    samplerate-subset = <16B 0x0000000080bb00000000000000000000>
    halle-calibration = "syscfg/PSCl"
    imic-mic = u64=0x0107020703000000
    ASP3 = u64=0x1048000007000000
    device_type = "audio-control"
    reg = <16B 0x4a000000e80300000000000000000000>
    ASP4 = u64=0x1848000000000000
    lmic-mic = u64=0x040a020a03000000

## /arm-io/aop-spmi0
    #interrupt-cells = u32=1 (0x01000000)
    interrupt-controller = <0B 0x>
    gen = u32=3 (0x03000000)
    compatible = "aapl,spmi"
    fatal-interrupts = u32=281 (0x19010000)
    interrupt-parent = <12B 0x9c000000200000009c000000>
    interrupts = <84B 0x00010000b001000019010000040100000501000008010000090100000a0100000c0100000d01000017010000180100001a0100001b0100001c0100001d010000100100001101000006010000070100000b010000>
    irq-behavior-map = <2B 0x0000>
    error-interrupts = <60B 0x040100000501000008010000090100000a0100000c0100000d01000017010000180100001a0100001b0100001c0100001d0100001001000011010000>
    reg = <48B 0x004091000100000000400000000000000040900001000000004000000000000000009000010000000040000000000000>
    device_type = "interrupt-controller"
    AAPL,phandle = u32=156 (0x9c000000)
    queue-depth = u64=0x0001000000010000
    #address-cells = u32=0 (0x00000000)
    other-interrupts = <12B 0x06010000070100000b010000>

## /arm-io/aop-spmi0/uwb0
    reg = <24B 0x0f0000000300000000000000040000000000000000000000>
    AAPL,phandle = u32=157 (0x9d000000)

## /arm-io/aop-spmi0/eclipse-heb
    reg = <24B 0x0e0000000300000000000000040000000000000000000000>
    AAPL,phandle = u32=158 (0x9e000000)

## /arm-io/aop-spmi0/baseband-heb
    capability = "billboard-via-message-buffer"
    msg-buffer-address-tx-billboard = u32=4224 (0x80100000)
    compatible = "baseband,heb"
    interrupt-parent = u32=156 (0x9c000000)
    interrupts = ["H", "D", "B"]
    reg = <24B 0x0d0000000300000000000000040000000000000000000000>
    AAPL,phandle = u32=159 (0x9f000000)
    irq-tx-offset-billboard-send = u32=18 (0x12000000)
    irq-tx-address-event-trigger = u32=1 (0x01000000)
    msg-buffer-address-tx-ocp = u32=4096 (0x00100000)
    msg-buffer-address-rx-ocp = u32=128 (0x80000000)
    irq-tx-offset-ocp-send = u32=13 (0x0d000000)
    #num-spmi-interrupts = u32=3 (0x03000000)

## /arm-io/aop-spmi0/stockholm-spmi
    compatible = "nfc,primary,spmi"
    interrupt-parent = u32=156 (0x9c000000)
    interrupts = <28B 0xb0000000b1000000b2000000b3000000b4000000b5000000b6000000>
    AAPL,phandle = u32=160 (0xa0000000)
    spmiFollowerReset = u32=1 (0x01000000)
    reg = <24B 0x080000000300000000000000040000000000000000000000>
    device_type = "stockholm-spmi"
    required-functions = ["support_host_wake_spmi", "support_data_over_spmi"]
    skip-spmi-reconfig = <0B 0x>
    #num-spmi-interrupts = u32=7 (0x07000000)
    nfccModel = u32=211 (0xd3000000)

## /arm-io/aop-spmi0/stockholm-spmi/stockholm
    required-gpios = ["support_venable", "support_virtual_gpio"]
    eos-halley-config = u32=1 (0x01000000)
    compatible = "nfc,primary,gpio"
    rf-antenna-name = "RTM7B_1"
    rf-config-tlvs = "A0130428282828A00D03610982A098088DAD0A8028171717A09E0C07401F9600FA002B52030000A0AF091178B0281159B02802A06A100000000000008C000000000000000000A0682A064060031914204000930400C04EC04E600160012001200103FA0000004C0008007D00007F0000010003"
    supports-nfc-reader-mode = <0B 0x>
    AAPL,phandle = u32=161 (0xa1000000)
    nfcWithRadio = u32=1 (0x01000000)
    device_type = "stockholm"
    function-enable = <20B 0x7700000038574b704f4963700000800000001500>

## /arm-io/aop-spmi0/hammerfest-spmi
    interrupt-parent = u32=156 (0x9c000000)
    compatible = "nfc,secondary,spmi"
    skip-spmi-reconfig = <0B 0x>
    interrupts = <28B 0xa0000000a1000000a2000000a3000000a4000000a5000000a6000000>
    AAPL,phandle = u32=162 (0xa2000000)
    #num-spmi-interrupts = u32=7 (0x07000000)
    required-functions = ["support_host_wake_spmi", "support_data_over_spmi"]
    reg = <24B 0x0c0000000300000000000000040000000000000000000000>
    device_type = "hammerfest-spmi"

## /arm-io/aop-spmi0/hammerfest-spmi/hammerfest
    required-gpios = ["support_venable", "support_virtual_gpio"]
    rf-antenna-name = "RTM7B_xS"
    compatible = "nfc,secondary,gpio"
    AAPL,phandle = u32=163 (0xa3000000)
    supports-nfc-reader-mode = <0B 0x>
    nfcWithRadio = u32=1 (0x01000000)
    device_type = "hammerfest"
    function-enable = <16B 0x590000004f4950470a00000001010000>

## /arm-io/aop-spmi1
    #interrupt-cells = u32=1 (0x01000000)
    interrupt-controller = <0B 0x>
    gen = u32=3 (0x03000000)
    compatible = "aapl,spmi"
    fatal-interrupts = u32=281 (0x19010000)
    interrupt-parent = <12B 0xa400000020000000a4000000>
    interrupts = <84B 0x00010000b401000019010000040100000501000008010000090100000a0100000c0100000d01000017010000180100001a0100001b0100001c0100001d010000100100001101000006010000070100000b010000>
    irq-behavior-map = <2B 0x0000>
    error-interrupts = <60B 0x040100000501000008010000090100000a0100000c0100000d01000017010000180100001a0100001b0100001c0100001d0100001001000011010000>
    reg = <48B 0x0040b1000100000000400000000000000040b0000100000000400000000000000000b000010000000040000000000000>
    device_type = "interrupt-controller"
    AAPL,phandle = u32=164 (0xa4000000)
    queue-depth = u64=0x0001000000010000
    #address-cells = u32=0 (0x00000000)
    other-interrupts = <12B 0x06010000070100000b010000>

## /arm-io/aop-spmi1/uwb
    reg = <24B 0x0f0000000300000000000000040000000000000000000000>
    AAPL,phandle = u32=165 (0xa5000000)

## /arm-io/aop-spmi1/eclipse-idc
    reg = <24B 0x0e0000000300000000000000040000000000000000000000>
    AAPL,phandle = u32=166 (0xa6000000)

## /arm-io/aop-spmi1/baseband-idc
    interrupt-parent = u32=164 (0xa4000000)
    compatible = "baseband,idc"
    reg = <24B 0x0d0000000300000000000000040000000000000000000000>
    interrupts = <44B 0x0000000000000000000000000000000000000000000000000000000000000000000000000000000002000000>
    AAPL,phandle = u32=167 (0xa7000000)
    #num-spmi-interrupts = u32=11 (0x0b000000)
    billboard-addr-rx-e85mitigation = "P"
    billboard-addr-tx-e85mitigation = " "
    irq-tx-offset-e85mitigation = u32=26 (0x1a000000)

## /arm-io/dp-audio1
    dma-channels = <32B 0x6600000002000000000000000008000000080000000000000000000000000000>
    power-gates = "]"
    dma-parent = "n"
    clock-gates = "]"
    function-device_reset_dpa = [""", "TSRA]"]
    device_type = "dp-audio1"
    AAPL,phandle = u32=212 (0xd4000000)

## /arm-io/iop-audio-controller
    AAPL,phandle = u32=273 (0x11010000)
    iop-audio-service-name = "AOPAudioService"
    compatible = "iop-audio,controller"
    device_type = "iop-audio-controller"

## /arm-io/iop-audio-controller/audio-hp
    external-power-provider = u32=307 (0x33010000)
    dma-channels = <128B 0xffffffff000000000000000000000000000000000000000000000000000000000900000022000000000000000003000080010000000000000000000000000000ffffffff000000000000000000000000000000000000000000000000000000000900000022000000000000000003000080010000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3301000043535061
    dma-parent = u32=307 (0x33010000)
    clock-domain = "niam"
    identifier = "iaph"
    device_type = "iop-audio-s"
    AAPL,phandle = u32=274 (0x12010000)

## /arm-io/iop-audio-controller/audio-hp/audio-codec
    compatible = "audio-data,cs42l79"
    reg = <36B 0x1112000004180100001bb7007d00010030000100000000000f0000000004001800000000>
    AAPL,phandle = u32=275 (0x13010000)
    data-sources = <27B 0x6132706108000100010001000000000080bb000048504d69637300>
    isolated-audio-service-input = u32=309 (0x35010000)
    device_type = "audio-data"
    device-uid = "HPMic"
    device-name = "HPMic"

## /arm-io/iop-audio-controller/audio-leap-internal-loopback
    external-power-provider = u32=306 (0x32010000)
    dma-channels = <128B 0x06000000210000000000000000030000c0000000000000000000000000000000070000002100000000000000c00300008001000000000000000000000000000006000000220000000000000000030000c0000000000000000000000000000000070000002200000000000000c003000080010000000000000000000000000000>
    compatible = "iop-adma-stream,leap"
    function-admac_powerswitch = u64=0x3201000043535061
    dma-parent = u32=306 (0x32010000)
    clock-domain = "niam"
    identifier = "blil"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=276 (0x14010000)

## /arm-io/iop-audio-controller/audio-leap-internal-loopback/audio-leap-internal-loopback
    compatible = "audio-data,external"
    audio-stream-formatter = "pael"
    reg = <36B 0x0142000002200100001bb700fa0001003000010003000000030000000202202003000000>
    data-sources = <48B 0x6132706102020400020001000000000080bb00004e6f6e536563757265204d4341204c454150204c6f6f706261636b00>
    AAPL,phandle = u32=277 (0x15010000)
    device_type = "leap-audio-data"
    device-uid = "NonSecure MCA LEAP Loopback"
    device-name = "NonSecure MCA LEAP Loopback"

## /arm-io/iop-audio-controller/audio-mca-loopback
    external-power-provider = u32=305 (0x31010000)
    dma-channels = <128B 0x000000002100000000000000c000000060000000000000000000000000000000010000002100000000000000c000000060000000000000000000000000000000000000002200000000000000c000000060000000000000000000000000000000010000002200000000000000c000000060000000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3101000043535061
    dma-parent = u32=305 (0x31010000)
    clock-domain = "niam"
    identifier = "kbpl"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=278 (0x16010000)

## /arm-io/iop-audio-controller/audio-mca-loopback/audio-mca-loopback
    device-name = "NonSecure MCA Loopback"
    compatible = "audio-data,audio-loopback"
    AAPL,phandle = u32=279 (0x17010000)
    data-sources = <43B 0x6332706102020000000001000000000080bb00004e6f6e536563757265204d4341204c6f6f706261636b00>
    device_type = "audio-data"
    reg = <36B 0x0112000002100100001bb700fa0001003000010003000000030000000202101003000000>
    device-uid = "NonSecure MCA Loopback"

## /arm-io/iop-audio-controller/audio-receiver
    external-power-provider = u32=305 (0x31010000)
    dma-channels = <128B 0x0600000021000000000000008004000000030000000000000000000000000000ffffffff000000000000000000000000000000000000000000000000000000000600000022000000000000008004000000030000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3101000043535061
    dma-parent = u32=305 (0x31010000)
    clock-domain = "niam"
    identifier = "vcer"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=280 (0x18010000)

## /arm-io/iop-audio-controller/audio-receiver/audio-receiver
    device-name = "Receiver"
    compatible = "audio-data,external"
    AAPL,phandle = u32=281 (0x19010000)
    data-sources = <29B 0x7232706100010000000001000000000080bb0000526563656976657200>
    registerWithPrimary = <0B 0x>
    device_type = "audio-data"
    reg = <36B 0x1112000004180100001bb7007d0001003000010001000000000000000100180000000000>
    device-uid = "Receiver"

## /arm-io/iop-audio-controller/audio-flicker
    external-power-provider = u32=305 (0x31010000)
    dma-channels = <128B 0xffffffff000000000000000000000000000000000000000000000000000000000b00000021000000000000006003000040020000000000000000000000000000ffffffff000000000000000000000000000000000000000000000000000000000b00000022000000000000006003000040020000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3101000043535061
    dma-parent = u32=305 (0x31010000)
    clock-domain = "niam"
    identifier = "kclf"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=282 (0x1a010000)

## /arm-io/iop-audio-controller/audio-flicker/audio-flicker
    device-name = "Flicker"
    compatible = "audio-data,external"
    AAPL,phandle = u32=283 (0x1b010000)
    data-sources = <28B 0x6632706102000400020001000000000080bb0000466c69636b657200>
    registerWithPrimary = <0B 0x>
    device_type = "audio-data"
    reg = <36B 0x0112000009000100001bb700fa0001003000010000000000800100000002001001000000>
    device-uid = "Flicker"

## /arm-io/iop-audio-controller/audio-s-leap-internal-loopback
    external-power-provider = u32=306 (0x32010000)
    dma-channels = <128B 0x04000000210000000000000000030000c0000000000000000000000000000000050000002100000000000000c00300008001000000000000000000000000000004000000220000000000000000030000c0000000000000000000000000000000050000002200000000000000c003000080010000000000000000000000000000>
    compatible = "iop-adma-stream,leap"
    function-admac_powerswitch = u64=0x3201000043535061
    dma-parent = u32=306 (0x32010000)
    clock-domain = "niam"
    identifier = "blls"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=284 (0x1c010000)

## /arm-io/iop-audio-controller/audio-s-leap-internal-loopback/audio-s-leap-internal-loopback
    compatible = "audio-data,external"
    audio-stream-formatter = "pael"
    reg = <36B 0x0142000002200100001bb700fa0001003000010003000000030000000202202003000000>
    data-sources = <45B 0x6132706102020400020001000000000080bb0000536563757265204d4341204c454150204c6f6f706261636b00>
    AAPL,phandle = u32=285 (0x1d010000)
    device_type = "leap-audio-data"
    device-uid = "Secure MCA LEAP Loopback"
    device-name = "Secure MCA LEAP Loopback"

## /arm-io/iop-audio-controller/lp-mic-device
    function-cm_power_change_notify = u64=0x900000006d73706c
    compatible = "iop-audio,lp-mic-device"
    identifier = "iapl"
    external-named-power-provider = "AppleCS42L79Audio"
    device_type = "lp-mic-device"
    AAPL,phandle = u32=286 (0x1e010000)

## /arm-io/iop-audio-controller/lp-mic-io-buffer-device
    exclave-assigned = <0B 0x>
    compatible = "iop-audio,isolated-io-buffer-device"
    exclave-service = "com.apple.service.AudioDriverLPMic"
    physical-descriptions = <24B 0x00fa0000803e00006d63706c0c0000000800000010040000>
    identifier = "xpda"
    exclave-edk-service = "com.apple.service.AudioDriverLPMic_EDK"
    external-named-power-provider = "SharedDARTMapperProxy"
    device_type = "lp-mic-io-buffer-device"
    AAPL,phandle = u32=287 (0x1f010000)

## /arm-io/iop-audio-controller/siri-listening-device
    supports-multiple-user-clients = <0B 0x>
    compatible = "iop-audio,client-manager-device"
    AAPL,phandle = u32=288 (0x20010000)
    identifier = " ial"
    publish-user-client = <0B 0x>
    external-named-power-provider = "AppleCS42L79Audio"
    device_type = "siri-listening-device"
    function-cm_power_change_notify = u64=0x90000000736c706c

## /arm-io/iop-audio-controller/lp-mic-injection-device
    external-power-provider = u32=305 (0x31010000)
    dma-channels = <128B 0x0e00000021000000000000008000000040000000000000000000000000000000ffffffff000000000000000000000000000000000000000000000000000000000e00000022000000000000006001000080000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3101000043535061
    identifier = "jipl"
    dma-parent = u32=305 (0x31010000)
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=289 (0x21010000)

## /arm-io/iop-audio-controller/lp-mic-injection-device/lp-mic-injection-device
    device-name = "LPMic Injection"
    compatible = "audio-data,external"
    terminal-type-output = "mjni"
    data-sources = <36B 0x6a69706c000800000200010000000000803e00004c504d696320496e6a656374696f6e00>
    AAPL,phandle = u32=290 (0x22010000)
    device_type = "audio-data"
    reg = <36B 0x0102000004000100001bb700ee020100100001000f000000000000000400100000000000>
    device-uid = "LPMicInjection"

## /arm-io/iop-audio-controller/audio-speaker-mca
    external-power-provider = u32=305 (0x31010000)
    dma-channels = <128B 0x0400000021000000000000002001000060000000000000000000000000000000050000002100000000000000c0060000800400000000000000000000000000000400000022000000000000002001000060000000000000000000000000000000050000002200000000000000c006000080040000000000000000000000000000>
    compatible = "iop-adma-stream,mca"
    function-admac_powerswitch = u64=0x3101000043535061
    dma-parent = u32=305 (0x31010000)
    clock-domain = "niam"
    identifier = "kpsm"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=291 (0x23010000)

## /arm-io/iop-audio-controller/audio-speaker-mca/audio-speaker
    AAPL,phandle = u32=292 (0x24010000)
    reg = <36B 0x115200000c100100001bb700fa0001003000010003000000ff0f0000020c101000011010>
    compatible = "audio-data,cs35l28"
    device_type = "audio-data"

## /arm-io/iop-audio-controller/audio-speaker
    iboot-audio-volume = u32=65407 (0x7fff0000)
    input-data-source-selectors = "0Vps0Ips02vs0res0fis0fvs1Vps1Ips12vs1res1fis1fvs"
    compatible = "audio-iop-speaker"
    speaker-config-0 = <36B 0x20706f74476d6370fd070000100000006c707069960000003f2808007672647001010303>
    speaker-config-1 = <36B 0x206d7462476d637000000000100000006c707069960000003f2809007672647001000303>
    output-data-source-selectors = "StoBSpoT"
    identifier = "rkps"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=293 (0x25010000)

## /arm-io/iop-audio-controller/audio-haptic
    audio-enable-warmup-ms = u32=3 (0x03000000)
    input-latency = u32=8 (0x08000000)
    compatible = "audio-control,audio-iop-haptics"
    function-haptics_session = u64=0x5501000063737068
    thermal-budget-range = <12B 0x4b0b0000fb0000004b0b0000>
    function-hall_ctrl = u64=0x900000006c6c6168
    model-name = "leap"
    function-thermal_budget = u64=0x5501000072656874
    peak-power-range = <12B 0x121600006105000012160000>
    uid = "Actuator"
    device_type = "iop-audio-ns"
    identifier = "chpa"
    output-latency = u32=8 (0x08000000)
    powered-on-state = "drwp"
    prewarm-on-state = " 1wp"
    AAPL,phandle = u32=294 (0x26010000)
    zerofill-buffer-size-ms = u32=5 (0x05000000)
    function-power_peak_budget = u64=0x5501000077706b70

## /arm-io/iop-audio-controller/audio-haptic-transport
    external-power-provider = u32=306 (0x32010000)
    dma-channels = <128B 0x020000002100000000000000c000000060000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000000020000002200000000000000c000000060000000000000000000000000000000ffffffff00000000000000000000000000000000000000000000000000000000>
    compatible = "iop-adma-stream,leap"
    function-admac_powerswitch = u64=0x3201000043535061
    dma-parent = u32=306 (0x32010000)
    clock-domain = "niam"
    identifier = " hpa"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=295 (0x27010000)

## /arm-io/iop-audio-controller/audio-haptic-transport/audio-haptic
    device_type = "leap-audio-data"
    reg = <36B 0x0142000001200200001bb700fa0001003000010001000000000000000100200002000000>
    AAPL,phandle = u32=296 (0x28010000)
    compatible = "audio-data,audio-iop-haptics"
    audio-stream-formatter = "pael"

## /arm-io/iop-audio-controller/audio-hw-pcm-audiomgr
    kci-name = "AOPAudioHWPCMAssetManagerInterface"
    AAPL,phandle = u32=297 (0x29010000)
    identifier = "Mmcp"
    compatible = "iop-audio,pcm-asset-manager-device"
    device_type = "iop-audio-ns"

## /arm-io/iop-audio-controller/audio-hpdbg
    input-latency = u32=5 (0x05000000)
    compatible = "audio-control,audio-iop-haptic-debug"
    uid = "Haptic Debug"
    AAPL,phandle = u32=298 (0x2a010000)
    model-name = "IOPHapticDebug"
    default-input-data-sources = "capacaocsopcbqes0Vra0Iraxlahylah"
    function-input-data-selectors = u64=0x5501000073696468
    powered-on-state = "drwp"
    input-data-source-selectors = "capacaoasopc0Ira0Vracaocstlf1cphdmchxlahtuocrxahpmtcpmts0Vps0Ipsuaxmjrtmnexm2cph3cph4cphspmsbqesnepmepoanepaocdiiddimilvuaoauapaylahryahffecdmcvxseryserpmrspmrppmrcdmcg0Vapagpctcmstclspdctopctccctglct2vctmuctagttpmtxpmtygwlsgtlfpmrtffosneotsopcwopsgcpatsextsevtsebtnibfphb0tst1tst2tst3tstqrihqrianevs1tni2tnitabvtsbv1bpm2bpmxlfrxcffxlffxcfstsfrcspacsoafvliig2acg2aitcsctcsitrpctrpivapcvap52apixmpicap52cpiwpscwpsiwpccwpcitcrctcrtck1ylfrycffylffycfstg2a"
    identifier = "cdha"
    output-latency = u32=5 (0x05000000)
    device_type = "iop-audio-ns"
    zerofill-buffer-size-ms = u32=5 (0x05000000)

## /arm-io/iop-audio-controller/audio-hpdbg-transport
    external-power-provider = u32=306 (0x32010000)
    dma-channels = <128B 0xffffffff000000000000000000000000000000000000000000000000000000000300000021000000000000000006000000030000000000000000000000000000ffffffff000000000000000000000000000000000000000000000000000000000300000022000000000000000006000000030000000000000000000000000000>
    compatible = "iop-adma-stream,leap"
    function-admac_powerswitch = u64=0x3201000043535061
    dma-parent = u32=306 (0x32010000)
    clock-domain = "niam"
    identifier = "dhpa"
    device_type = "iop-audio-ns"
    AAPL,phandle = u32=299 (0x2b010000)

## /arm-io/iop-audio-controller/audio-hpdbg-transport/audio-hpdbg
    device_type = "leap-audio-data"
    reg = <36B 0x11120000080002000080bb00000101003000010000000000ff0000000008101001010000>
    AAPL,phandle = u32=300 (0x2c010000)
    compatible = "audio-data,audio-iop-hpdbg"
    audio-stream-formatter = "pael"

## /arm-io/iop-audio-controller/audio-haptic-leap
    remote-node-interface = u32=302 (0x2e010000)
    compatible = "iop-audio,haptics-leap-control-device"
    AAPL,phandle = u32=301 (0x2d010000)
    identifier = "cmpl"
    parking-node-id = "Nkrp"
    device_type = "iop-audio-ns"
    kci-name = "AppleHapticsAudioInterface"

## /arm-io/iop-audio-controller/audio-haptic-parking
    AAPL,phandle = u32=302 (0x2e010000)
    identifier = "Nkrp"
    device_type = "iop-audio-ns"

## /arm-io/iop-voicetrigger-controller
    AAPL,phandle = u32=303 (0x2f010000)
    iop-audio-service-name = "AOPVoiceTriggerService"
    compatible = "iop-audio,controller"
    device_type = "iop-voicetrigger-controller"

## /arm-io/iop-voicetrigger-controller/audio-vt-device
    exclave-assigned = <0B 0x>
    compatible = "iop-audio,isolated-vt-device"
    exclave-service = "com.apple.service.AudioDriverVT"
    identifier = "mctv"
    exclave-edk-service = "com.apple.service.AudioDriverVT_EDK"
    device_type = "iop-nub"
    AAPL,phandle = u32=304 (0x30010000)

## /arm-io/admac-base-ns
    channel-buffer-alloc-base-rx = u32=0 (0x00000000)
    compatible = "admac,t8140"
    interrupt-parent = " "
    interrupts = u32=449 (0xc1010000)
    #dma-channels = u32=13 (0x0d000000)
    clock-gates = u32=299 (0x2b010000)
    channels-offset = u32=0 (0x00000000)
    iommu-parent = "M"
    device_type = "admac"
    channel-buffer-allocation = <16B 0x001e000000000000001e000000000000>
    irq-destination-index = u32=0 (0x00000000)
    reg = <32B 0x0000800301000000004003000000000000802af8000000000800000000000000>
    AAPL,phandle = u32=305 (0x31010000)
    channel-buffer-alloc-base-tx = u32=0 (0x00000000)
    role = "SNAB"
    irq-destinations = " CIAUPCA NTGDSNU"

## /arm-io/admac-leap-ns
    channel-buffer-alloc-base-rx = u32=0 (0x00000000)
    compatible = "admac,t8140"
    interrupt-parent = " "
    interrupts = u32=452 (0xc4010000)
    #dma-channels = u32=9 (0x09000000)
    clock-gates = u32=299 (0x2b010000)
    channels-offset = u32=0 (0x00000000)
    iommu-parent = "N"
    device_type = "admac"
    channel-buffer-allocation = <16B 0x000e0000000000000011000000000000>
    irq-destination-index = u32=0 (0x00000000)
    reg = <32B 0x0000300301000000004003000000000000802af8000000000800000000000000>
    AAPL,phandle = u32=306 (0x32010000)
    channel-buffer-alloc-base-tx = u32=0 (0x00000000)
    role = "SNEL"
    irq-destinations = " CIAUPCA NTGDSNU"

## /arm-io/admac-base-s
    #dma-channels = u32=13 (0x0d000000)
    clock-gates = u32=299 (0x2b010000)
    irq-destination-index = u32=0 (0x00000000)
    channel-buffer-allocation = <16B 0x00020000000000000040000000000000>
    channels-offset = u32=0 (0x00000000)
    irq-destinations = " CIAUPCA NTGDSNU"
    AAPL,phandle = u32=307 (0x33010000)
    iommu-parent = <0B 0x>
    interrupt-parent = " "
    channel-buffer-alloc-base-tx = u32=0 (0x00000000)
    service-exclave_proxy = "DMAChannelProxy@admac-base-s-proxy"
    channel-buffer-alloc-base-rx = u32=0 (0x00000000)
    compatible = "admac,t8140"
    interrupts = u32=448 (0xc0010000)
    #skip-channels-tx = u32=1 (0x01000000)
    skip-channels-rx = u64=0x010000000c000000
    role = "SSAB"
    #skip-channels-rx = u32=2 (0x02000000)
    device_type = "admac"
    reg = <32B 0x0000700301000000004003000000000000802af8000000000800000000000000>
    skip-channels-tx = u32=12 (0x0c000000)

## /arm-io/admac-base-s-proxy
    exclave-assigned = <0B 0x>
    compatible = "admac-ec-proxy"
    reg = <16B 0x00007053030000000040030000000000>
    AAPL,phandle = u32=308 (0x34010000)
    exclave-service = "com.apple.service.AudioDriver"
    exclave-edk-service = "com.apple.service.AudioDriver_EDK"
    use-case = "iaph"
    device_type = "admac-proxy"
    dma-channel = u32=4 (0x04000000)
    function-iommu_handler = u64=0x3601000072706473

## /arm-io/audio-hp-proxy
    exclave-assigned = <0B 0x>
    compatible = "iisaudio,isolated-stream-proxy"
    exclave-service = "com.apple.service.HPMicAudioDriver"
    physical-descriptions = <24B 0xe03d000080bb00006d63706c040000001000000018040000>
    identifier = "iaph"
    exclave-edk-service = "com.apple.service.HPMicAudioDriver_EDK"
    device_type = "iis-ec-proxy"
    AAPL,phandle = u32=309 (0x35010000)

## /arm-io/audio-shared-dart-proxy
    exclave-assigned = <0B 0x>
    exclave-service = "com.apple.service.AudioSharedDARTMapper"
    iommu-parent = "O"
    exclave-edk-service = "com.apple.service.AudioSharedDARTMapper_EDK"
    usecase-dart-map = ["iaph", "xpda", "Okps", "vcer"]
    AAPL,phandle = u32=310 (0x36010000)

## /arm-io/haptics-support-interface
    clcl-cal = "syscfg/CLCL"
    compatible = "haptics-support,leap"
    pscl-cal = "syscfg/PSCl"
    tcal-cal = "syscfg/TCal"
    device_type = "haptics-support-interface"
    AAPL,phandle = u32=341 (0x55010000)

## /arm-io/audio-resource-manager
    AAPL,phandle = u32=342 (0x56010000)
    kci-name = "AudioResourceManagerInterface"
    resource-gid-mapping = <43B 0x00000100204d4350414f50417564696f485750434d41737365744d616e61676572496e7465726661636500>
    compatible = "audio,embedded-resource-manager"
    device_type = "audio-resource-manager"

## /arm-io/grimaldi
    AAPL,phandle = u32=345 (0x59010000)
    compatible = "aop,h16,vd5b704"
    function-grimaldi-power-set = ["E", "Srwp"]
    function-grimaldi-device-id = ["E", "Ived"]
    function-grimaldi-power-get = ["E", "Grwp"]
    host = "AOP"
    device_type = "grimaldi"
    function-grimaldi-gain = ["E", "niag"]
