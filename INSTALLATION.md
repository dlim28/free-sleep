# Requirements

## Compatability
- Pod 1 - ❌ **NOT COMPATIBLE**
- Pod 2 - ❌ **NOT COMPATIBLE**


- Pod 3 - **(With SD card)** - ✅  _most people who have tried this have gotten it working_
  - **USE LINUX FOR THIS**
    - Option 1:
      - Follow the steps [here](https://blopker.com/writing/04-zerosleep-1/) to get root
      - Start from step 11 **(SKIP step 12)**
      - It's important you run step 11 ASAP after you ssh in, or else your pod will auto update firmware and kick you out
    - Option 2:
      - Try [this script](https://github.com/Pixel-Meister/freesleep_script/blob/main/modify_eight_sleep.sh) to modify 8 sleeps SD card (I have not personally tested this)


- Pod 3 - **(No SD card)** - ✅ FCC ID: 2AYXT61100001 (The FCC ID is located in the back of the pod where you plug in the water tubes)
- Pod 4 ✅
- Pod 5 ✅


## Tools required
- [TC2070-IDC ($50)](https://www.tag-connect.com/product/tc2070-idc) - You can also solder the 3 required wires to the JTAG header instead
- [FTDI FT232RL ($13)](https://www.amazon.com/gp/product/B07TXVRQ7V/)
- [Dupont wires ($7)](https://www.amazon.com/Elegoo-EL-CP-004-Multicolored-Breadboard-arduino/dp/B01EV70C78)
- PSA - The instructions contained here are specific to mac and linux. If you have Windows, you'll have to figure that out yourself (it's do-able, I just refuse to use Windows)

---

## How to revert changes and go back to using your Eight Sleep through their app
1. If you already had your pod added to your 8 sleep account in your app, go to your 8 sleep app and manage your pod, remove the pod from your account
2. Reset the firmware
    1. [Pod 3](docs/pod_3_teardown/6_firmware_reset.jpeg)
    1. [Pod 4](docs/pod_4_teardown/3_reset_firmware.png)
3. Set up the pod as a new pod in the app

---
# Installation Steps


## 1. Access the circuit board
1. **Pod 5 users only**: you must first setup your pod with the 8 sleep app, then proceed
1. Follow the steps to teardown your device and get access to the circuit board
   1. [Pod 3](docs/pod_3_teardown) 
   1. [Pod 4](docs/pod_4_teardown)
       1. [Pod 4 written instructions](docs/pod_4_teardown/instructions.md)

---

## 2. Connect to device

1. Your pod should be unplugged at this point. It doesn't need a connection to the mattress cover OR power at this point
1. Using dupont wires, connect your tag-connect cable to your FTDI FT232RL following the images in [docs/jtag/](docs/jtag/)
1. Connect your tag-connect cable to the circuit board 
   1. [Pod 3](docs/pod_3_teardown/7_pod_3_board_connection.jpeg)
   1. [Pod 4](docs/pod_4_teardown/2_circuit_board.png)
1. Connect your FTDI FT232RL to your computer 

---

## 3. Get the minicom session ready on your computer
- The baud rate is 921600
- Run `ls /dev/tty*`, you should see your FT232RL listed under something like `tty.usbserial-B0010NHK`
```
minicom -b 921600 -o -D /dev/tty.usbserial-B0010NHK
```
- You should see this screen (at least on Mac), if you don't run `ls /dev/tty*`, your device might be under something else

![docs/installation/0_minicom.png](docs/installation/0_minicom.png)


---

## 4. Plug the power into the pod  

Get ready to interrupt the boot when you see `Hit any key to stop autoboot`. (I just hit CTRL + C)

![Interrupt](docs/installation/1_interrupt.png)

If you did it correctly, you'll see this 

![Interrupt success](docs/installation/2_shell.png)

---


## 5.Modify the boot environment, this allows us to get root access

```
# VERIFY your current_slot = a, if not, go back and firmware reset your pod
# If it's still not = a, create an issue in github 
printenv current_slot

# If you have current_slot=a
setenv bootargs "root=PARTLABEL=rootfs_a rootwait init=/bin/bash"

run bootcmd
```

---


## 6. Mount the file system

```
# Mount /proc for process and system information
mount -t proc proc /proc

# Mount /sys for hardware and system-level information
mount -t sysfs sysfs /sys

# Mount /dev for device files (e.g., /dev/mmcblk0)
mount -t devtmpfs devtmpfs /dev

# Mount /run (optional but useful for some runtime scripts)
mount -t tmpfs tmpfs /run

# Mount the file system in read write mode (BE CAREFUL EDITING MODIFYING FILES)
mount -o remount,rw /
```

---


## 7. Update password for root & rewt

```
passwd root
passwd rewt
```
---


## 8. Sync the file changes

```
sync
```

---


## 9. Reboot (DO NOT INTERRUPT BOOT THIS TIME)

```
reboot -f
```

---

## 10. Login as root with the password we set
On the pod 4 & 5, this screen will be slightly different, that's OK

![Login](docs/installation/3_login.png)

---


## 11. Disable software updates

You may see some failures saying these services were not loaded or do not exist, that's ok
```
# Disables the software updates
systemctl disable --now swupdate-progress swupdate defibrillator eight-kernel telegraf vector frankenfirmware dac swupdate.socket

# Blocks the software updates if we ever restart or power off the device
systemctl mask swupdate-progress swupdate defibrillator eight-kernel telegraf vector frankenfirmware dac swupdate.socket
```

---

## 12. Setup internet access

```
# Replace WIFI_NAME and PASSWORD with your actual WiFi credentials
# (WIFI_NAME appears twice)
# 
# DO NOT USE A GUEST NETWORK OR TRY TO DO ANYTHING FANCY TO PREVENT IT FROM TALKING TO THE INTERNET
#   If you want to block internet access to the pod, we can do that with firewall rules later

nmcli connection add type wifi con-name WIFI_NAME ifname wlan0 ssid WIFI_NAME wifi-sec.key-mgmt wpa-psk wifi-sec.psk "PASSWORD" ipv4.method auto ipv6.method auto

# (OPTIONAL) This will take your Pod out of the "waiting to be setup" state, and will allow you to turn off the blue blinking LED.
sed -i 's/uuid=.*/uuid=700a7a76-2105-4f46-b1b4-c9f3c791c440/' /persistent/system-connections/*.nmconnection

# Reload the network manager
nmcli connection reload
```

---


## 13. Install the free-sleep app, this will set up a systemctl service that auto runs on boot
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/throwaway31265/free-sleep/main/scripts/install.sh)"
```

- Running the same command again on a Pod that already has Free Sleep is safe: the current installation is kept at `/home/dac/free-sleep-backup` until the new one installs, migrates, and stays running, and it is restored automatically if anything fails. Settings, schedules, and biometrics data are kept.
- To install from a fork or branch (for example, to test changes), set both variables and fetch the installer from the same place:
```
FREE_SLEEP_REPO=<github-user>/free-sleep FREE_SLEEP_BRANCH=<branch> /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<github-user>/free-sleep/<branch>/scripts/install.sh)"
```
  Updates started from the web app always use `throwaway31265/free-sleep` `main`. To update from a fork or branch, run `FREE_SLEEP_REPO=<github-user>/free-sleep FREE_SLEEP_BRANCH=<branch> sh /home/dac/free-sleep/scripts/update.sh`.

---


## 14. Get your pod's IP address

```
# Yours will be different, that's okay
nmcli -g ip4.address device show wlan0
192.168.1.50/24
```

---


## 15. With a device connected to the SAME Wi-Fi network you set up in step 12, navigate to your pod's IP address (port 3000)

SET YOUR TIME ZONE, OR ELSE SCHEDULING WILL NOT WORK! This can be done on the settings page of the web app. See screenshot below. The site should appear but it should be loading and dulled out. (Unless you have the pod plugged into the cover)

http://192.168.1.50:3000/

![Web App](docs/installation/4_web_app.png)

---

## 16. Save the website to your home screen on your mobile device
- Apple devices:
  - Navigate to the website in safari
  - Click the share icon in the bottom toolbar
  - Select 'Add to Home Screen'
  - Edit the name if you’d like, then tap Add.
  - The shortcut will now appear on your home screen like an app icon.
- Android devices:
  - Open the website in Chrome (or your default browser). 
  - Tap the three-dot menu in the top-right corner. 
  - Select “Add to Home screen” (sometimes shown as “Install app”). 
  - Edit the name if you’d like, then tap Add. 
  - The shortcut will now appear on your home screen like an app icon.



## 17. Validation

### Verify the site is still up
1. Unplug the power from your device and plug it back in 
2. Wait up to 4 minutes or so, ensure you can still access the site from another device
3. If the site is still up, you should be good. NOTE - The website will not fully load until the Pod is connected to the mattress cover. Once it's plugged in to the cover the site should load and work correctly.

### Verify the controls work
1. I would recommend setting up steps 17 and 18 below (block WAN traffic & setup SSH access for debugging & upgrading free-sleep)
2. Disconnect the tag-connect cable and power from your pod
3. Connect your pod to the cover as you normally would 
4. Using the free-sleep site, set a temperature. (I would suggest the highest temp on one side and the lowest temp on the other side)
5. Physically verify the temps change (lay on the cover, use a thermometer, whatever)
6. If the temps change, you're all set! 
7. If it's not working, reach out in Discord and share the output of `fs-debug`

## 18. Add an ssh config
- This will ask for a public key, ssh access is on port 8822 (ex: `ssh root@<POD_IP> -p 8822`)
- This allows you to set up remote root access to your Pod (root login and password authentication stay enabled, as before)
- The new `/etc/ssh/sshd_config` is checked with `sshd -t` first; if it is invalid, the existing config is kept. The default `/etc/ssh/authorized_keys` is removed.
- Older versions of this script also copied the server config over `/etc/ssh/ssh_config` (the client config), which breaks `ssh`/`scp` commands run *from* the Pod (incoming SSH was not affected). Re-running the script repairs that file when it recognizes the copy, saving the damaged file as `/etc/ssh/ssh_config.server-copy.bak.<date>`. A client config with your own settings is left unchanged.
- Keep your current SSH session open until a new `ssh root@<POD_IP> -p 8822` session succeeds.
```
sh /home/dac/free-sleep/scripts/setup_ssh.sh
```

## 19. Add firewall rules to block access to the internet (optional, but recommended)
```
# Block internet access (also applied after every reboot)
sh /home/dac/free-sleep/scripts/block_internet_access.sh

# Also block Sentry error reporting (remembered until you run ALLOW_SENTRY=true ...)
ALLOW_SENTRY=false sh /home/dac/free-sleep/scripts/block_internet_access.sh

# Temporary unblock until the next reboot or until you re-apply your setting
sh /home/dac/free-sleep/scripts/unblock_internet_access.sh
sh /home/dac/free-sleep/scripts/block_internet_access.sh --restore-prior-state

# Keep internet access unblocked, including after reboots and updates
sh /home/dac/free-sleep/scripts/unblock_internet_access.sh --persistent
```
- Blocking applies immediately, including to connections that were already open (the previous rules let existing connections continue).
- Still allowed: your local network (including SSH on port 8822 and the web app on port 3000), loopback, DHCP, NTP time sync, DNS to the Pod's configured DNS servers, IPv6 local addresses and neighbor/router discovery, and Sentry unless `ALLOW_SENTRY=false`.
- Free Sleep only manages its own chains (`FREE_SLEEP_IN`/`FREE_SLEEP_OUT`, and `FREE_SLEEP_IN6`/`FREE_SLEEP_OUT6` for IPv6). Your other filter and NAT rules are not flushed. Rules left by older versions of this script are removed automatically.
- Your choice (blocked/unblocked and Sentry) is saved in `/persistent/free-sleep-data/firewall_config.env`. Updates and biometrics setup unblock temporarily for downloads and then restore that choice. If you have never chosen, they block afterwards, as they always have.
- DNS servers are read from `/etc/resolv.conf`, `resolvectl`, and `nmcli` when the rules are applied. If your router or DNS servers change, run the block command again. To pin specific DNS servers, list one IP per line in `/persistent/free-sleep-data/dns_servers.txt`. If no DNS server can be found, DNS is allowed to any server so time sync keeps working.

### Update safety and recovery
- Updates (`fs-update` or the web app) stop Free Sleep, take a verified database backup at `/persistent/free-sleep-data/free-sleep-copy.db`, and keep the current installation at `/home/dac/free-sleep-backup`.
- An update is refused, with nothing changed, if there isn't enough free space for the download and a separate copy of the server dependencies.
- Database migrations run with `prisma migrate deploy`, which never prompts or resets data. If the download, dependencies, migration, or the post-start check of the server fails, the previous installation and database are restored and restarted automatically.
- If the restore itself fails, the update exits with status 3, leaves Free Sleep stopped, and prints the manual recovery steps. After a power loss during an update, recover manually with:
```
rm -rf /home/dac/free-sleep && mv /home/dac/free-sleep-backup /home/dac/free-sleep
cp /persistent/free-sleep-data/free-sleep-copy.db /persistent/free-sleep-data/free-sleep.db
rm -f /persistent/free-sleep-data/free-sleep.db-wal /persistent/free-sleep-data/free-sleep.db-shm
chown dac:dac /persistent/free-sleep-data/free-sleep.db
systemctl enable free-sleep && systemctl start free-sleep
```


#### Free sleep commands available (run this in the terminal through an SSH session on your pod)
- `fs-debug` - Prints a debug report  for the pod & free sleep
- `fs-restart` - Restarts the free sleep service
- `fs-reset-db` - Deletes the biometrics DB and recreates it (helpful for corrupted DB files)
- `fs-reset` - Wipes free-sleep data and does a fresh install (can fix corrupted DB or issues switching from beta branch to main branch (requires confirmation in a prompt before executing)
- `fs-update` - Manually runs the update script
- `fs-dev-server` - Run express server with nodemon (for devs)
