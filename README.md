# uhd-rfsoc

[![CI](https://github.com/functions-lab/uhd-rfsoc/actions/workflows/ci.yml/badge.svg)](https://github.com/functions-lab/uhd-rfsoc/actions/workflows/ci.yml)

**Unleash the full capability of your RFSoC with uhd-rfsoc.**

**TL;DR:** uhd-rfsoc is an RFSoC driver for UHD, so you can use your board
as a standard UHD device. Every ecosystem built around UHD (GNU Radio,
OCUDU, Duranta and more) works out of the box.

Supported boards, each with multiple sample-rate and channel-count options:

- [**Xilinx RFSoC ZCU216**](https://www.amd.com/en/products/adaptive-socs-and-fpgas/evaluation-boards/zcu216.html) (16T16R)
- [**Real Digital RFSoC4x2**](https://www.realdigital.org/hardware/rfsoc-4x2) (2T4R)
- **Other Xilinx RFSoC boards**: Work in progress
<!-- Demo video placeholder. Replace the block below with the video: drag
     the .mp4 into the GitHub editor, or link a thumbnail to it. -->
> **Demo video.**

```sh
uhd_find_devices --args type=rfsoc
uhd_usrp_probe --args type=rfsoc,channels=4
benchmark_rate --args type=rfsoc --rx_rate 1.25e9 --tx_rate 1.25e9
```

## Quick start

**[QUICK_START.md](QUICK_START.md)** helps you jump start a RFSoC board with fresh PYNQ image and run a GNU Radio demo.

## Sampling rate options

The data rate on the 100 GbE link is the channel count times the
per-channel I/Q sample rate times the size of one sample on the wire:

$$R = N \cdot f_s \cdot b_{\text{otw}} \;\le\; 99\ \text{Gb/s}$$

| symbol | meaning |
|---|---|
| $N$ | channel count |
| $f_s$ | per-channel I/Q sample rate, which is also the bandwidth |
| $b_{\text{otw}}$ | bits per I/Q sample of the over-the-wire (OTW) format: 32 for sc16, 24 for sc12, 16 for sc8 |
| 99 Gb/s | what 100 GbE carries after packet headers |

Example with $N = 4$ on a ZCU216:

| $f_s$ (MS/s) | sc16 | sc12 | sc8 | formats that fit |
|---|---|---|---|---|
| 625 | 80 Gb/s | 60 Gb/s | 40 Gb/s | sc16, sc12, sc8 |
| 833.33 | 107 Gb/s, too much | 80 Gb/s | 53 Gb/s | sc12, sc8 |
| 1250 | 160 Gb/s, too much | 120 Gb/s, too much | 80 Gb/s | sc8 only |

Choose the channel count with the device argument `channels=N` and the
sample rate with the application's usual rate option:

```sh
# 4 channels at 625 MS/s each, sc16 (the default format)
uhd-rfsoc benchmark_rate --args type=rfsoc,channels=4 --channels 0,1,2,3 --rx_rate 625e6 --tx_rate 625e6
# 4 channels at 1250 MS/s each: only sc8 fits, so ask for it
uhd-rfsoc benchmark_rate --args type=rfsoc,channels=4,otw=sc8 --channels 0,1,2,3 --rx_rate 1.25e9 --rx_otw sc8 --rx_cpu sc8
```

A request is met from below: you get the highest supported rate at or below
the one you ask for.

How to read the table:

- **Bold** rates are the LTE / 5G NR rates.
- A rate tagged <sub>sc12</sub> is too fast for sc16 on that channel count:
  it needs sc12 or sc8. A rate tagged <sub>sc8</sub> needs sc8. Untagged
  rates fit in every format.
- The carrier is set per channel anywhere in the range, without an external
  front end.

| board | f_RFDC (GS/s) | carrier (MHz) | channels | max f_s in sc16 / sc12 / sc8 (MS/s) | supported f_s per channel (MS/s) |
|---|---|---|---|---|---|
| **ZCU216** | 2.5 | 0 .. 1250 | 1 | 1250 / 1250 / 1250 | 62.5, 104.17, 125, 156.25, 208.33, 250, 312.5, 416.67, 500, 625, 833.33, 1250 |
| | | | 2 | 1250 / 1250 / 1250 | 62.5, 104.17, 125, 156.25, 208.33, 250, 312.5, 416.67, 500, 625, 833.33, 1250 |
| | | | 4 | 625 / 833.33 / 1250 | 62.5, 104.17, 125, 156.25, 208.33, 250, 312.5, 416.67, 500, 625, 833.33 <sub>sc12</sub>, 1250 <sub>sc8</sub> |
| | | | 8 | 312.5 / 500 / 625 | 62.5, 104.17, 125, 156.25, 208.33, 250, 312.5, 416.67 <sub>sc12</sub>, 500 <sub>sc12</sub>, 625 <sub>sc8</sub> |
| | | | 16 | 156.25 / 250 / 312.5 | 62.5, 104.17, 125, 156.25, 208.33 <sub>sc12</sub>, 250 <sub>sc12</sub>, 312.5 <sub>sc8</sub> |
| | 2.4576 | 0 .. 1228.8 | 1 | 1228.8 / 1228.8 / 1228.8 | **61.44**, 102.4, **122.88**, 153.6, 204.8, **245.76**, 307.2, 409.6, **491.52**, 614.4, 819.2, 1228.8 |
| | | | 2 | 1228.8 / 1228.8 / 1228.8 | **61.44**, 102.4, **122.88**, 153.6, 204.8, **245.76**, 307.2, 409.6, **491.52**, 614.4, 819.2, 1228.8 |
| | | | 4 | 614.4 / 819.2 / 1228.8 | **61.44**, 102.4, **122.88**, 153.6, 204.8, **245.76**, 307.2, 409.6, **491.52**, 614.4, 819.2 <sub>sc12</sub>, 1228.8 <sub>sc8</sub> |
| | | | 8 | 307.2 / 491.52 / 614.4 | **61.44**, 102.4, **122.88**, 153.6, 204.8, **245.76**, 307.2, 409.6 <sub>sc12</sub>, **491.52** <sub>sc12</sub>, 614.4 <sub>sc8</sub> |
| | | | 16 | 153.6 / 245.76 / 307.2 | **61.44**, 102.4, **122.88**, 153.6, 204.8 <sub>sc12</sub>, **245.76** <sub>sc12</sub>, 307.2 <sub>sc8</sub> |
| | 2.4 | 0 .. 1200 | 1 | 1200 / 1200 / 1200 | 60, 100, 120, 150, 200, 240, 300, 400, 480, 600, 800, 1200 |
| | | | 2 | 1200 / 1200 / 1200 | 60, 100, 120, 150, 200, 240, 300, 400, 480, 600, 800, 1200 |
| | | | 4 | 600 / 800 / 1200 | 60, 100, 120, 150, 200, 240, 300, 400, 480, 600, 800 <sub>sc12</sub>, 1200 <sub>sc8</sub> |
| | | | 8 | 300 / 480 / 600 | 60, 100, 120, 150, 200, 240, 300, 400 <sub>sc12</sub>, 480 <sub>sc12</sub>, 600 <sub>sc8</sub> |
| | | | 16 | 150 / 240 / 300 | 60, 100, 120, 150, 200 <sub>sc12</sub>, 240 <sub>sc12</sub>, 300 <sub>sc8</sub> |
| **RFSoC 4x2** | 5.0 | 0 .. 2500 | 1 | 2500 / 2500 / 2500 | 125, 208.33, 250, 312.5, 416.67, 500, 625, 833.33, 1000, 1250, 1666.67, 2500 |
| | | | 2 | 1250 / 1666.67 / 2500 | 125, 208.33, 250, 312.5, 416.67, 500, 625, 833.33, 1000, 1250, 1666.67 <sub>sc12</sub>, 2500 <sub>sc8</sub> |
| | 4.9152 | 0 .. 2457.6 | 1 | 2457.6 / 2457.6 / 2457.6 | **122.88**, 204.8, **245.76**, 307.2, 409.6, **491.52**, 614.4, 819.2, 983.04, 1228.8, 1638.4, 2457.6 |
| | | | 2 | 1228.8 / 1638.4 / 2457.6 | **122.88**, 204.8, **245.76**, 307.2, 409.6, **491.52**, 614.4, 819.2, 983.04, 1228.8, 1638.4 <sub>sc12</sub>, 2457.6 <sub>sc8</sub> |
| | 4.8 | 0 .. 2400 | 1 | 2400 / 2400 / 2400 | 120, 200, 240, 300, 400, 480, 600, 800, 960, 1200, 1600, 2400 |
| | | | 2 | 1200 / 1600 / 2400 | 120, 200, 240, 300, 400, 480, 600, 800, 960, 1200, 1600 <sub>sc12</sub>, 2400 <sub>sc8</sub> |

Note:

- **The OTW format is sc16 by default.** Pass the device argument `otw=sc8`
  or `otw=sc12` to ask for another one. Without it, a request for a tagged
  rate is served at the fastest sc16 rate instead.

## GNU Radio demo

The 4-channel GNU Radio flowgraph with uhd-rfsoc, each DAC cabled to its ADC: 625 MS/s
per channel in sc16 type, a 10 MHz tone on a 950 MHz carrier.

| GNU Radio flowgraph | Spectrum of RX 0-3 | RX 0-3 with TX shifted 90° apart |
|:---:|:---:|:---:|
| ![The 4-channel flowgraph](docs/img/gnuradio_flowgraph.png) | ![Spectrum of the four RX channels](docs/img/gnuradio_spectrum.png) | ![Time plots of the four RX channels](docs/img/gnuradio_phase.png) |

- **Standard UHD blocks only:** UHD USRP Sink and Source, Qt GUI sinks.
- **Spectrum:** Clean tone at expected frequency band.
- **Phaser control:** one phase per TX and RX channel

## 5G NR with OCUDU and Duranta

Two open-source 5G RAN stacks, [OCUDU](https://ocudu.org) and
[Duranta](https://lfnetworking.org/projects/duranta/), run unmodified as Split 8
gNBs with an RFSoC board as their radio.

![The eight tested gNB-UE pairs](docs/img/5g_setup.png)

- **Pairs 1-4, over cable:** OCUDU gNB and srsUE on a 20 MHz FDD cell in
  band n28. The RFSoC boards run at 122.88 MS/s, the USRP X310 at
  23.04 MS/s.
- **Pairs 5-8, over the air:** a commodity phone on a 100 MHz TDD cell in
  band n78 at 3609.99 MHz, the second Nyquist zone of the RFSoC 4x2.
- **Hosts:** an x86 workstation, or an Arm-based NVIDIA DGX Spark.