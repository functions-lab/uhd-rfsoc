# fpga/Makefile -- the bitstreams of every board, one flow (flow/build.tcl,
# flow/ladder.sh) fed by each board's directory (boards/<board>/: board.tcl,
# builds.txt, block_designs/). The Vivado release comes from the PYNQ version
# (flow/versions.txt) and must be on PATH. See README.md.
#
#   make package                                    repackage the UHD cores (after a source change)
#   make BOARD=<b> templates [FS=<MS/s>]            the board's run-time-rate templates
#   make BOARD=<b> bitstream N=<n> [F=<f>] [FS=<MS/s>] [STEP=bd|synth|bit|impl]
#   make BOARD=<b> ladder [FS=<MS/s>]               every build of boards/<b>/builds.txt
#   make BOARD=<b> list                             the builds and what is built
#   make BOARD=<b> clean                            delete the build directory
#   make versions                                   the PYNQ versions and their Vivado releases
#   options: PYNQ=<v> (the image to build for; default 2.7 = Vivado 2021.1)
#            BUILD_DIR=<dir> (default build/<b>, or build/pynq<v>/<b> for another PYNQ)
#            MAXPAR=2 (builds at a time) JOBS=6 (threads each) STRATEGY=<impl strategy>
#            STEP=bd (block design only, minutes) SKIP_EXISTING=1
BOARDS := $(notdir $(patsubst %/board.tcl,%,$(wildcard boards/*/board.tcl)))
BOARD  ?=
N      ?=
F      ?=
FS     ?=
STEP   ?= bit
JOBS   ?= 6
MAXPAR ?= 2
PYNQ   ?= $(shell flow/versions.sh default)
# the release that builds for PYNQ (empty: unknown PYNQ, check-vivado says so)
VIVADO_VERSION := $(shell flow/versions.sh vivado $(PYNQ) 2>/dev/null)
BUILD_DIR ?= $(shell flow/versions.sh builddir $(PYNQ) $(BOARD) 2>/dev/null)
OUT    := $(abspath $(BUILD_DIR))
# what build.tcl / ladder.sh take from the environment
V49_ENV = V49_VIVADO=$(VIVADO_VERSION) V49_PYNQ=$(PYNQ) V49_OUT=$(OUT)

.PHONY: help package templates bitstream ladder list clean versions check-board check-vivado
help:
	@sed -n '1,/^BOARDS/p' Makefile | grep '^#' | sed 's/^# \{0,1\}//'
	@echo "boards: $(BOARDS)"

check-board:
	@[ -n "$(BOARD)" ] || { echo "set BOARD= (one of: $(BOARDS))"; exit 2; }
	@[ -f boards/$(BOARD)/board.tcl ] || { echo "unknown BOARD=$(BOARD) (one of: $(BOARDS))"; exit 2; }
check-vivado:
	@[ -n "$(VIVADO_VERSION)" ] || { echo "unknown PYNQ=$(PYNQ) (one of: $$(flow/versions.sh pynqs))"; exit 2; }
	@v=$$(vivado -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1); \
	[ "$$v" = "v$(VIVADO_VERSION)" ] || { echo "PYNQ $(PYNQ) needs Vivado $(VIVADO_VERSION) on PATH (found: $${v:-none}); source <Vivado>/settings64.sh"; exit 2; }

versions:
	@printf "%-6s %-8s %s\n" PYNQ Vivado "build directory (BOARD=<b>)"; \
	for p in $$(flow/versions.sh pynqs); do \
	    printf "%-6s %-8s %s\n" $$p $$(flow/versions.sh vivado $$p) $$(flow/versions.sh builddir $$p '<b>'); done

package: check-vivado
	$(MAKE) -C ip/src/uhd_ip package

templates: check-board check-vivado
	$(V49_ENV) KIND=template FS=$(FS) MAXPAR=$(MAXPAR) JOBS=$(JOBS) SKIP_EXISTING=$(SKIP_EXISTING) flow/ladder.sh $(BOARD) $(STEP)
ladder: check-board check-vivado
	$(V49_ENV) KIND= FS=$(FS) MAXPAR=$(MAXPAR) JOBS=$(JOBS) SKIP_EXISTING=$(SKIP_EXISTING) flow/ladder.sh $(BOARD) $(STEP)

# one build; only the bitstream (+ .hwh, reports) is kept: the Vivado project
# is deleted when Vivado exits, whatever the step or outcome (V49_KEEP_PROJ=1 keeps it)
bitstream: check-board check-vivado
	@[ -n "$(N)" ] || { echo "set N= (channel count)"; exit 2; }
	@mkdir -p $(OUT); pf=$$(mktemp); \
	$(V49_ENV) V49_PROJ_FILE=$$pf V49_IMPL_STRATEGY="$(STRATEGY)" vivado -mode batch -nojournal -nolog \
	    -source flow/build.tcl -tclargs $(BOARD) $(N) $(STEP) $(JOBS) "$(F)" "$(FS)"; rc=$$?; \
	p=$$(cat $$pf); rm -f $$pf; \
	if [ -n "$$p" ] && [ "$${V49_KEEP_PROJ:-0}" != 1 ]; then rm -rf $(OUT)/$$p; echo "deleted $(OUT)/$$p"; fi; \
	exit $$rc

list: check-board
	@printf "%-38s %-9s %s\n" build kind "status (built / TIMING-FAIL / - not built)"
	@grep -v '^#' boards/$(BOARD)/builds.txt | while read -r n f fs kind s; do \
	    [ -n "$$n" ] || continue; \
	    name=$(BOARD)_v49_$${n}ch_qsfp_f$${f}_fs$$(echo $$fs | tr . p); \
	    if [ -f $(OUT)/bitstreams/$$name.bit ]; then st=built; \
	    elif [ -f $(OUT)/bitstreams_timing_fail/$$name.bit ]; then st=TIMING-FAIL; else st=-; fi; \
	    printf "%-38s %-9s %s\n" $$name $$kind $$st; done

clean: check-board
	rm -rf $(OUT)
