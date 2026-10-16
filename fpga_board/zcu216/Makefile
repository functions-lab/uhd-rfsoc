# fpga_board/zcu216/Makefile -- the ZCU216 as a UHD device over 100 GbE: the v49
# bitstreams (N = 1, 2, 4, 8, 16 channels). One self-contained block design,
# block_designs/zcu216_uhd_v49/, built by scripts/v49_build.tcl into
# build/v49_qsfp/ (needs the packaged cores: `make v49-package` first, and
# Vivado 2021.1 on PATH).
#   make v49 N=1 F=2 [FS=<MS/s>] [STEP=bd|synth|bit|impl] [JOBS=12]   one build (fs 2400 default)
#   make v49 N=2 F=4 STRATEGY=Performance_ExtraTimingOpt              another impl strategy
#   make v49-ladder [STEP=bd|bit] [MAXPAR=3] [JOBS=8]                 every build (scripts/v49_ladder.sh)
#   make v49-templates [STEP=bd|bit] [MAXPAR=3] [JOBS=8]              the 5 run-time-rate templates
N    ?= 1
F    ?=
FS   ?=
STEP ?= bit
JOBS ?= 12
MAXPAR ?= 3
# The run-time-rate templates (Protocol §8): each channel count's top
# normal-family build. MTS_clk_wiz has dynamic reconfiguration, so the daemon
# serves every lower factor of that N from it (1ch: 1250 .. 62.5 MS/s).
TEMPLATES := ^zcu216_v49_(1ch_qsfp_f2_fs2500|2ch_qsfp_f2_fs2500|4ch_qsfp_f3_fs2250|8ch_qsfp_f6_fs2250|16ch_qsfp_f12_fs2250)$$
.PHONY: v49 v49-ladder v49-templates v49-package
# Only the bitstream (+ .hwh, reports) is kept: the Vivado project is deleted
# when Vivado exits, whatever the step or outcome (V49_KEEP_PROJ=1 keeps it).
v49:
	@pf=$$(mktemp); V49_PROJ_FILE=$$pf V49_IMPL_STRATEGY="$(STRATEGY)" vivado -mode batch -nojournal -nolog \
	    -source scripts/v49_build.tcl -tclargs $(N) $(STEP) $(JOBS) $(F) $(FS); rc=$$?; \
	p=$$(cat $$pf); rm -f $$pf; \
	if [ -n "$$p" ] && [ "$${V49_KEEP_PROJ:-0}" != 1 ]; then rm -rf build/v49_qsfp/$$p; echo "deleted build/v49_qsfp/$$p"; fi; \
	exit $$rc
v49-ladder:
	MAXPAR=$(MAXPAR) JOBS=$(JOBS) scripts/v49_ladder.sh $(STEP)
v49-templates:
	ONLY='$(TEMPLATES)' MAXPAR=$(MAXPAR) JOBS=$(JOBS) scripts/v49_ladder.sh $(STEP)
v49-package:
	$(MAKE) -C ../../fpga_ip/ip_design/uhd_ip package
