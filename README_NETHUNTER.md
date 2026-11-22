# Kernel NetHunter dla Samsung Galaxy A70 (a70q, SM-A705F / SM-A705FN)

Źródło bazowe: [MrR0b0X/Nethunter_kernel_samsung_a70q](https://github.com/MrR0b0X/Nethunter_kernel_samsung_a70q)
(Linux 4.14.190), rozbudowane o pełną obsługę NetHuntera i CARsenal.

| Gałąź | ROM | Bazowy defconfig |
|---|---|---|
| `ccr-9d3f66c9-d5co1b` (stock-11) | Samsung stock Android 11 / One UI 3.1 (np. A705FNXXU5DXD2) | `nethunter_defconfig` |
| `lineage-20` | LineageOS 20 (Android 13) | `neternels_defconfig` |

Na obu gałęziach finalny config powstaje jako
`bazowy defconfig + arch/arm64/configs/nethunter-extras.config`.
Skrypt `build_nethunter.sh` po scaleniu sprawdza, czy każda opcja
z pliku extras faktycznie weszła do `.config`, i przerywa build, jeśli nie.

## Co dodano

### CARsenal (car hacking)
* **SocketCAN**: `CAN`, `CAN_RAW`, `CAN_BCM`, `CAN_GW`, `CAN_DEV`
* **ISO-TP (ISO 15765-2)**: `CAN_ISOTP`, czyli backport
  [hartkopp/can-isotp](https://github.com/hartkopp/can-isotp) do `net/can/isotp.c`
  (w 4.14 go nie ma; potrzebny do UDS/OBD-II, isotpsend/isotprecv/isotpdump)
* **Wirtualne CAN**: `CAN_VCAN` (np. ICSim), `CAN_VXCAN`
* **slcan**: `CAN_SLCAN` (CANable/CANtact w trybie slcan, adaptery serial-CAN)
* **Adaptery USB-CAN**: gs_usb (CANable/candleLight), PEAK PCAN-USB, Kvaser,
  EMS, ESD, 8devices, Microchip CAN BUS Analyzer
* **USB-serial** (ELM327/OBD-II, slcan, UART): FTDI, PL2303, CH341, CP210x,
  Cypress M8, ARK3116, F81232, MCT U232, TI, option/qualcomm (modemy), ACM
* **Bluetooth RFCOMM**, czyli ELM327 po BT (`rfcomm bind`)

### Wi-Fi (monitor mode i injection)
* rtl8812au aircrack-ng v5.6.4.2 (`88XXAU=y`): RTL8812AU/8821AU/8814AU
  (Alfa AWUS036ACH, AWUS036AC, AWUS1900)
* rtl8188eus aircrack-ng v5.3.9 (`RTL8188EUS=m`, moduł `8188eu.ko`):
  TP-Link TL-WN722N v2/v3. Jest modułem, bo ma te same symbole co rtl8812au.
  Jeśli kartę przejmie `rtl8xxxu`, odepnij ją i załaduj moduł:
  `echo <id> > /sys/bus/usb/drivers/rtl8xxxu/unbind; insmod 8188eu.ko`
* ath9k_htc (AR9271, Alfa AWUS036NHA), carl9170, rt2800usb (wszystkie warianty,
  AWUS036NH/ACM), rt73usb, rt2500usb, rtl8187 (AWUS036H), rtl8xxxu, mt7601u,
  zd1211rw, p54usb, ar5523, rndis_wlan
* `CFG80211_WEXT` (iwconfig), `MAC80211_MESH`

### Bluetooth
Zewnętrzne dongle USB/UART (btusb + BCM/RTL, H4, BCSP, ATH3K), RFCOMM, BNEP, HIDP, VHCI.

### USB Arsenal i HID
Gadget configfs: **HID** (klawiatura/mysz, DuckHunter, BadUSB), **RNDIS**,
ECM, EEM, NCM, ACM, serial, mass storage, FunctionFS.
Host: hidraw, uhid, hiddev.

### Sieć, MITM, kontenery
TUN, veth, dummy, macvlan/macvtap, 802.1Q VLAN, bridge, GRE/IPIP/SIT,
TPROXY i socket match, MASQUERADE/REDIRECT (v4 i v6), packet/inet/unix diag,
SysV IPC, POSIX mqueue, namespaces (UTS/IPC/PID/NET), binfmt_misc
(qemu-user w chroot), overlayfs, FUSE, loop, squashfs, ISO9660, UDF,
USB storage i UAS. Adaptery Ethernet USB: AX88179/AX8817x, RTL8152/8153,
RTL8150, CDC Ether/EEM/NCM, RNDIS host, SMSC, DM9601, LAN78xx, iPhone (ipheth).

### Ładowanie modułów na Samsungu
Samsung ma w kernelu `CONFIG_UH_LKM_BLOCK=y`, które **bezwarunkowo odrzuca każdy
moduł `.ko`**. Dlatego moduły od NetHuntera nie ładowały się na bazowym kernelu.
Tutaj wyłączono `UH_LKMAUTH`, `UH_LKM_BLOCK`, DEFEX, PROCA i FIVE, a włączono
`MODULE_FORCE_LOAD` i `/proc/config.gz`.
Zip AnyKernel3 zawiera zbudowane moduły (`do.modules=1`).

## Budowanie

```bash
./build_nethunter.sh          # config, kernel, moduły i zip AnyKernel3 w out/
./build_nethunter.sh config   # tylko config i weryfikacja opcji
```

Toolchain [proton-clang](https://github.com/kdrag0n/proton-clang) (clang 13
z binutils) pobiera się sam do `toolchain/`. AnyKernel3: `MrRob0-X/anykernel3`, gałąź `a70q`.

Na GitHubie każdy push uruchamia workflow **Build NetHunter kernel (a70q)**
(można go też odpalić ręcznie w zakładce Actions). Gotowy zip pojawia się
w artefaktach.

## Instalacja

1. Odblokowany bootloader, TWRP i Magisk.
2. Zrób backup partycji `boot` w TWRP.
3. Wgraj `NetHunter-a70q-*.zip` w TWRP.
4. Zainstaluj NetHunter (aplikację i chroot) z Magiska lub NetHunter Store.
5. Sprawdź kernel: `uname -r` powinno zwrócić `4.14.190-NetHunter-J4n3K`,
   a `zcat /proc/config.gz | grep CAN_ISOTP` powinno dać `=y`.

Kernel z gałęzi stock-11 wgrywaj tylko na stockowy ROM, a z `lineage-20` tylko na LineageOS 20.

### Szybki test CARsenal

```bash
ip link add dev vcan0 type vcan && ip link set up vcan0
candump vcan0 &  cansend vcan0 123#DEADBEEF
# ELM327/slcan po USB:
slcand -o -c -s6 /dev/ttyUSB0 slcan0 && ip link set up slcan0
# CANable (gs_usb):
ip link set can0 type can bitrate 500000 && ip link set up can0
```
