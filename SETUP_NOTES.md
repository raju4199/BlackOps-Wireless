# BlackOps Wireless -- Setup Notes (Kali VM + USB WiFi Adapter)

## 1. Adapter requirements

You need a **monitor-mode and packet-injection capable** USB WiFi
adapter. Onboard laptop WiFi almost never supports this once it's behind
a VM's virtualized network adapter. Common chipsets known to work well
with aircrack-ng/Airgeddon:

- Realtek RTL8812AU / RTL8811AU (dual-band, injection-capable with the
  right driver -- `rtl8812au` or `88XXau` DKMS driver)
- Atheros AR9271 (2.4GHz only, very reliable, driver in-kernel on Kali)
- Ralink RT3070 (older but rock solid, in-kernel driver)

Check chipset before buying if going this route -- plenty of "great
reviews" adapters use chipsets with poor Linux monitor-mode support.

## 2. Passing the adapter into the VM

### VirtualBox
1. Install the VirtualBox Extension Pack (needed for USB 2.0/3.0
   passthrough).
2. Plug in the adapter on the host.
3. VM Settings -> USB -> enable USB controller -> add a USB device filter
   for your adapter.
4. Start the VM. Devices -> USB -> confirm the adapter is checked
   (passed through), not still attached to the host.

### VMware Workstation/Player
1. Plug in the adapter on the host.
2. With the VM running: VM -> Removable Devices -> [adapter name] ->
   Connect (Disconnect from Host).
3. If VMware Tools intercepts it, use the tray icon (bottom right) to
   route the device to the guest instead.

### VMware Fusion / Parallels (macOS host)
- Similar removable-devices menu; note macOS may need the adapter
  "captured" for the guest each time it's reconnected.

## 3. Verifying the adapter is visible and supports monitor mode

Inside the Kali guest, after passthrough:

```bash
lsusb                     # confirm adapter shows up
iw dev                    # confirm a wlan interface exists
iw list | grep -A 10 "Supported interface modes"   # look for "monitor"
```

If `iw list` doesn't show `monitor` support, the driver either isn't
loaded correctly or the chipset genuinely doesn't support it -- check
`dmesg | tail -50` for driver errors.

## 4. Enabling monitor mode

`lab.sh` -> option 2 does this for you, or manually:

```bash
sudo airmon-ng check kill   # stops NetworkManager/wpa_supplicant from
                             # fighting over the interface
sudo airmon-ng start wlan0  # creates wlan0mon (name may vary)
iw dev                       # confirm the mon interface exists
```

To go back to managed mode afterward:

```bash
sudo airmon-ng stop wlan0mon
sudo systemctl restart NetworkManager
```

## 5. Isolating the lab network

- Use a spare/cheap router or your phone's hotspot as the test AP --
  don't test against your real home router's live SSID.
- Put the test AP on a channel and SSID clearly labeled (e.g.
  `LAB-TEST-DO-NOT-USE`) so you never confuse it with a neighbor's
  network mid-scan.
- If the test AP has WAN/internet access, consider disabling it so
  nothing captured/relayed can reach the outside world.

## 6. Snapshot the VM

Before running anything, take a clean VirtualBox/VMware snapshot so you
can revert after each exercise (driver crashes and interface renames are
common with monitor mode).
