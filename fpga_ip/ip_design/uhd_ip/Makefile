# uhd_ip -- the UHD / 100GbE data-plane cores (udp_streamer, udp_player,
# axis_pkt_arb, ch_interleave, tx_beamformer, rx_beamformer): sources,
# testbenches and IP packaging.
#
#   src/            the RTL (Verilog-2001, XPM macros); register maps in the headers
#   sim/            xsim testbenches + Python checkers (wire format: the Protocol, top AGENTS.md)
#   package_ip.tcl  -> ../../ip/uhd_ip/<core>_1.0 (user.org:uhd:<core>:1.0), the IP
#                   repo the v49 block designs import (zcu216_uhd_v49.tcl, rfsoc4x2_uhd_v49.tcl)
#   ooc_timing.tcl  out-of-context synth + place + route timing check
#
# After any change under src/: make sim sim-fmt && make package, and commit
# src/ together with ../../ip/uhd_ip.
# Vivado 2021.1: the one on PATH, else Xilinx's default install location
VIVADO_ROOT ?= $(or $(patsubst %/bin/vivado,%,$(realpath $(shell command -v vivado 2>/dev/null))),/tools/Xilinx/Vivado/2021.1)
VIVADO      := $(VIVADO_ROOT)/bin/vivado

.PHONY: all sim sim-streamer sim-player sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf sim-arb package ooc clean

all: sim sim-fmt sim-max sim-wide sim-interleave sim-bf sim-rbf sim-arb

# sc16 regression: S_WIDTH/M_WIDTH 128/256/512 x TICK_STEP 1/2
sim: sim-streamer sim-player
sim-streamer:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim.sh
sim-player:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim_player.sh

# over-the-wire format sweep (Protocol §10): sc16/sc8/sc12/fc32 x 128/256/512
sim-fmt:
	VIVADO_ROOT=$(VIVADO_ROOT) FMTS="0 1 2 3" TICK_STEPS=1 sim/run_sim.sh
	VIVADO_ROOT=$(VIVADO_ROOT) FMTS="0 1 2 3" TICK_STEPS=1 sim/run_sim_player.sh

# max-rate geometry: 512-bit beats at 300 MHz (a 16-slot group per cycle,
# 4.8 GS/s): sc8 / sc12 must neither overflow nor underflow; sc16 there is
# beyond the 100G link (drops allowed). Plus the 2 MiB TX buffer.
sim-max:
	VIVADO_ROOT=$(VIVADO_ROOT) FAST=1 WIDTHS=512 TICK_STEPS=1 FMTS="1 2 0" sim/run_sim.sh
	VIVADO_ROOT=$(VIVADO_ROOT) FAST=1 WIDTHS=512 TICK_STEPS=1 FMTS="1 2" sim/run_sim_player.sh
	VIVADO_ROOT=$(VIVADO_ROOT) FAST=1 TXBW=32768 WIDTHS=512 TICK_STEPS=1 FMTS=1 sim/run_sim_player.sh

# sc8max geometry: 1024-bit beats at 187.5 MHz (one sc8 wire word per cycle,
# 6 GS/s, 96 Gb/s), sc8 only: sc8 must neither overflow nor underflow; the
# streamer must drop (and count) every packet of the other formats.
sim-wide:
	VIVADO_ROOT=$(VIVADO_ROOT) WIDTHS=1024 TICK_STEPS=1 FMTS="1 0 2 3" sim/run_sim.sh
	VIVADO_ROOT=$(VIVADO_ROOT) WIDTHS=1024 TICK_STEPS=1 FMTS=1 sim/run_sim_player.sh
	VIVADO_ROOT=$(VIVADO_ROOT) TXBW=32768 WIDTHS=1024 TICK_STEPS=1 FMTS=1 sim/run_sim_player.sh

sim-interleave:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim_interleave.sh

# axis_pkt_arb against its previous skid-buffer form (sim/axis_pkt_arb_skid_ref.v):
# every port, every cycle, random traffic and backpressure
sim-arb:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim_arb.sh

# beamformers (Protocol §11), every v49 (N_CH, BEAT_W, clock) geometry
sim-bf:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim_bf.sh
sim-rbf:
	VIVADO_ROOT=$(VIVADO_ROOT) sim/run_sim_rbf.sh

package:
	$(VIVADO) -mode batch -nojournal -nolog -notrace -source package_ip.tcl

# the deployed converter geometries, all at the 300 MHz worst case (128, 256
# and 512-bit beats); the player with the 2 MiB (32768-word) TX buffer;
# tx_clk 322.27 MHz
OOC_CFGS := udp_streamer:128:300 udp_streamer:256:300 udp_streamer:512:300 \
            udp_player:128:300 udp_player:256:300 udp_player:512:300 \
            udp_streamer:1024:187.5 udp_player:1024:187.5
ooc:
	mkdir -p ooc
	cd ooc && for c in $(OOC_CFGS); do \
	  set -- $$(echo $$c | tr : ' '); \
	  $(VIVADO) -mode batch -nojournal -log ooc_$$1_$$2.log -source ../ooc_timing.tcl \
	    -tclargs $$1 $$2 $$3 ooc_$$1_$$2 $$([ $$1 = udp_player ] && echo TX_BUF_WORDS=32768) \
	    > /dev/null & \
	done; wait; grep -h OOC_RESULT ooc_*.log

clean:
	rm -rf sim/build* ooc .pkg_tmp .Xil
