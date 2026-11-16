# Quick start: clone and run the GNU Radio demo

From a fresh board and host to the GNU Radio demo of uhd-rfsoc, in four
steps. What the project is and what it can do: [README.md](README.md).

You need:

- **Board:** a [ZCU216](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/zcu216.html)
  or [RFSoC 4x2](https://www.realdigital.org/hardware/rfsoc-4x2) running PYNQ 2.7, 3.0 or 3.1, on the LAN,
  with a QSFP28 100G cable to the host. No PYNQ on it yet:
  [flash the SD card](#before-you-start-pynq-on-the-sd-card) first.
- **Host:** Linux (x86_64 or aarch64) with a ConnectX-5, -6 or -7
  100G NIC. We tested with UHD 4.6, DPDK 23.11 and GNU Radio 3.10 but it is 
  possible that other versions will still work.

## Before you start: PYNQ on the SD card

Skip this if your board already boots PYNQ 2.7, 3.0 or 3.1. PYNQ is
delivered as an SD card image; the PYNQ websites have the images and the
full instructions, summarised here.

**1. Download the image of your board**, in PYNQ 2.7, 3.0 or 3.1:

| board | where the image is |
|---|---|
| RFSoC 4x2 | the [PYNQ board images page](https://www.pynq.io/boards.html) |
| ZCU216 | PYNQ publishes no image for it: the RFSoC-PYNQ page [Other RFSoC boards](https://www.rfsoc-pynq.io/boards.html) links the community image and the instructions to build one |

**2. Write it to a microSD card** (16 GB or more) with
[balenaEtcher](https://etcher.balena.io/), which runs on Windows, macOS and
Linux:

1. Unzip the download to get the `.img` file.
2. Insert the card and open balenaEtcher.
3. **Flash from file**: choose the `.img`.
4. **Select target**: choose the card.
5. **Flash!**, and wait until the write and its validation finish.

PYNQ's own instructions are in
[Writing an SD Card Image](https://pynq.readthedocs.io/en/latest/appendix/sdcard.html).

**3. Boot the board from the card.** Insert the card, set the boot mode
switch to SD, connect the board's Ethernet port to your LAN and power it on.
The RFSoC 4x2's
[getting started guide](https://www.rfsoc-pynq.io/rfsoc_4x2_getting_started.html)
shows the switch and the boot sequence (about a minute); for the ZCU216 the
switch setting is in the board's user guide.

**4. Log in.** The board takes its address from DHCP. The RFSoC 4x2 shows
it on its display; for a ZCU216, look it up in your router's client list or
on the USB serial console (115200 baud, `ip addr`). The user is `xilinx`,
password `xilinx`:

```sh
ssh-copy-id xilinx@<board-ip>               # once: step 2 copies the bitstreams over ssh without a password
ssh xilinx@<board-ip>
```

## 1. Clone (on the PC)

```sh
git clone https://github.com/functions-lab/uhd-rfsoc.git && cd uhd-rfsoc
```

No submodule is needed: step 2 fetches only the bitstreams of your board.
They all come from
[uhd-rfsoc-bitstream](https://github.com/functions-lab/uhd-rfsoc-bitstream),
which also offers one zip per board and PYNQ version in its
[releases](https://github.com/functions-lab/uhd-rfsoc-bitstream/releases).

## 2. Set up the board (on the board, user `xilinx`)

```sh
git clone https://github.com/functions-lab/uhd-rfsoc.git ~/jupyter_notebooks/uhd-rfsoc
cd ~/jupyter_notebooks/uhd-rfsoc
sudo rfsoc/setup_board.sh                   # once
```

Set `data_ip` in `rfsoc/server/uhd_rfsoc.conf`: the FPGA's 100G address, on
the subnet of the host's 100G port. Then install the bitstreams from the PC
and start the daemon:

```sh
# on the PC: asks the board for its type and PYNQ version, downloads that
# one set (15-55 MB) and copies it to the board
rfsoc/get_bitstreams.sh xilinx@<board-ip>
# on the board
./run_daemon.sh                             # returns once it serves (~20 s)
```

## 3. Set up the host (on the PC)

```sh
sudo apt install libuhd-dev uhd-host python3-uhd libboost-dev gnuradio \
    dpdk libdpdk-dev rdma-core ibverbs-providers cmake g++ pkg-config
sudo host/setup_cx5.sh <100g-iface> <host-data-ip>/24   # RS-FEC, MTU 9000, address
sudo host/setup_dpdk.sh <100g-iface> --install          # hugepages, driver checks
sudo nmcli device set <100g-iface> managed no           # keep NetworkManager off the port
cmake -S host -B host/build -DCMAKE_BUILD_TYPE=Release
cmake --build host/build -j && sudo cmake --install host/build
```

## 4. Run

```sh
uhd_find_devices --args type=rfsoc          # the board answers; no root needed
host/gnuradio/run_tones.sh 4                # ZCU216: 4T4R at 625 MS/s per channel
host/gnuradio/run_tones.sh 1 -r 2.5e9       # RFSoC 4x2: 1T1R at 2500 MS/s
```

Run it from a terminal on the PC's desktop; it asks for the sudo password,
because the DPDK data plane needs root. Cable each DAC to its ADC to see the
tones of the [GNU Radio demo](README.md#gnu-radio-demo).

Any other UHD application runs through the `uhd-rfsoc` wrapper, which adds
`sudo` and finds UHD's examples:

```sh
uhd-rfsoc tx_waveforms --args type=rfsoc,channels=2 --rate 625e6 --freq 950e6 --wave-type SINE --wave-freq 10e6
```

| device argument | meaning |
|---|---|
| `addr=<board-ip>` | which board; without it, the one discovery finds |
| `channels=N` | the channel count (default 1); a new N reloads the bitstream (~16 s) |
| `otw=sc8` / `sc12` | a narrower wire format, for the orange and red rates of the [rate table](README.md#sampling-rate-options) |

Troubleshooting: `rfsoc/README.md` for the board, `host/README.md` for the
host.
