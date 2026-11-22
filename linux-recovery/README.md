# Linux-recovery dla Galaxy A70 (a70q)

Ten sam pomysł co `Linux11.img` dla Galaxy A51: na partycję **RECOVERY** wgrywasz
kernel z małym initramfsem (busybox). Initramfs uruchamia zwykłego Linuksa
(Debian, Kali, Arch ARM, Ubuntu, postmarketOS, ...). Android zostaje na BOOT, więc masz dual boot:

| Chcesz uruchomić | Jak |
|---|---|
| Linux | `adb reboot recovery`, w Magisku *Reboot → Recovery*, albo wyłącz telefon i trzymaj Vol+ i Power (na Androidzie 11 z podłączonym kablem USB) |
| Android | w Linuksie `reboot`, w powłoce ratunkowej `reboot -f` |

Uwaga: zamiast TWRP masz wtedy Linuksa na recovery. Zachowaj obraz TWRP, żeby móc go przywrócić.

## Gdzie init szuka systemu (pierwsze trafienie wygrywa)

1. `linux.root=<urządzenie | LABEL=... | UUID=...>` w cmdline (opcjonalnie)
2. **`/data/linux.img`**: plik z obrazem systemu plików na partycji userdata
   (ścieżkę zmienisz przez `linux.img=/inny.img`)
3. **partycja z etykietą `LINUX`** na microSD lub pendrive (`linux.label=` zmienia etykietę)
4. jeśli nic nie znajdzie, uruchamia **powłokę ratunkową przez USB**:
   * Ethernet po USB (ECM): `telnet 172.16.42.1` (PC dostaje adres 172.16.42.2 z DHCP)
   * port szeregowy: `/dev/ttyACM0` na PC (`picocom /dev/ttyACM0`)

Po starcie Linuksa userdata Androida jest zamontowana w `/mnt/android-data`.

> Na tym kernelu wyświetlacz (Qualcomm SDE) nie ma działającego fbdev, więc **na
> ekranie nie ma konsoli tekstowej**. Obraz daje dopiero DRM/KMS w userspace:
> Wayland/sway/Phosh, Xorg z modesetting albo kmscon. Wcześniej masz SSH, telnet
> lub serial po USB. W sway/wlroots wyłącz wirtualne wyjście writeback:
> `output Virtual-1 disable`. Tak to rozwiązano w [a70q-pmos](https://github.com/h3nr1-d14z/a70q-pmos).

## Budowanie

```bash
./build_linux_recovery.sh
# wynik w out-recovery/:
#   linux-recovery-a70q-<gałąź>-<data>.img       -> TWRP: Install Image -> Recovery
#   linux-recovery-a70q-<gałąź>-<data>-odin.tar  -> Odin: AP (albo heimdall --RECOVERY)
```

Kernel to ten sam NetHunter (`nethunter-extras.config`) z dodatkami z
`linux-recovery/recovery.config`. Najważniejsze z nich: devtmpfs, loop, ext4/f2fs,
opcje wymagane przez systemd oraz **wyłączony `ANDROID_PARANOID_NETWORK`**
(bez tego zwykły użytkownik w Linuksie nie otworzy gniazda sieciowego).

Nagłówek obrazu domyślnie odpowiada TWRP dla a70q: header v1, page 4096,
`recovery_dtbo`, os_version 11.0.0, patch 2025-12. Najpewniej jest jednak
skopiować nagłówek z obrazu, który już bootuje na Twoim telefonie (TWRP albo stockowy recovery.img):

```bash
LIKE_IMG=~/twrp-a70q.img ./build_linux_recovery.sh
python3 linux-recovery/mkbootimg.py --info out-recovery/linux-recovery-*.img
```

Bootloader Samsunga odrzuca obraz, którego `os_patch_level` jest starszy niż ostatnio
uruchomiony. Wtedy podaj `OS_PATCH_LEVEL=2026-01` (lub nowszy) albo użyj `LIKE_IMG`.

## Przygotowanie systemu

### Wariant A: `/data/linux.img`
Rób to w Androidzie jako root, w Termux albo `adb shell su`:

```sh
truncate -s 16G /data/linux.img
mke2fs -t ext4 -L LINUX /data/linux.img
mkdir -p /data/local/mnt && mount -o loop /data/linux.img /data/local/mnt
# rozpakuj rootfs arm64, np. Kali NetHunter rootfs albo Debian:
tar -xpf /sdcard/kali-nethunter-rootfs-full-arm64.tar.xz -C /data/local/mnt
# wymagane: /sbin/init w rootfs (systemd lub inny init), ustaw hasło roota (chroot + passwd)
umount /data/local/mnt
```

Plik leży bezpośrednio w `/data`, poza katalogami szyfrowanymi przez FBE, więc
initramfs odczyta go bez kluczy Androida.

### Wariant B: microSD
Na PC utwórz partycję ext4 z etykietą `LINUX`
(`mkfs.ext4 -L LINUX /dev/sdX2`) i rozpakuj na nią rootfs arm64.

### Zalecane w rootfs
* sterowniki Wi-Fi/modemu Qualcomma wymagają firmware z partycji `vendor` i `modem`
  (pełna konfiguracja w [a70q-pmos](https://github.com/h3nr1-d14z/a70q-pmos));
* `echo 0 > /proc/sys/kernel/hung_task_timeout_secs` ustawia już initramfs
  (watchdog Knox potrafi zrestartować telefon przy długim fsck).

## Parametry cmdline

| Parametr | Domyślnie | Opis |
|---|---|---|
| `linux.root=` | brak | urządzenie, `LABEL=` lub `UUID=` |
| `linux.img=` | `/linux.img` | ścieżka obrazu względem userdata |
| `linux.label=` | `LINUX` | etykieta partycji na microSD lub USB |
| `linux.init=` | `/sbin/init` | init w rootfs |
| `linux.shell=1` | brak | od razu powłoka ratunkowa przez USB |

Parametry dopiszesz przy budowaniu przez `mkbootimg.py --append-cmdline` (zmienna w skrypcie).
