# fpga/Makefile -- the bitstreams of every board, one flow (flow/build.tcl,
# flow/ladder.sh) fed by each board's directory (boards/<board>/: board.tcl,
# builds.txt, block_designs/). Vivado 2021.1 on PATH. See README.md.
#
#   make package                                    repackage the UHD cores (after a source change)
#   make BOARD=<b> templates [FS=<MS/s>]            the board's run-time-rate templates
#   make BOARD=<b> bitstream N=<n> [F=<f>] [FS=<MS/s>] [STEP=bd|synth|bit|impl]
#   make BOARD=<b> ladder [FS=<MS/s>]               every build of boards/<b>/builds.txt
#   make BOARD=<b> list                             the builds and what is built
#   make BOARD=<b> clean                            delete build/<b>/
#   options: MAXPAR=2 (builds at a time) JOBS=6 (threads each) STRATEGY=<impl strategy>
#            STEP=bd (block design only, minutes) SKIP_EXISTING=1
BOARDS := $(notdir $(patsubst %/board.tcl,%,$(wildcard boards/*/board.tcl)))
BOARD  ?=
N      ?=
F      ?=
FS     ?=
STEP   ?= bit
JOBS   ?= 6
MAXPAR ?= 2
VIVADO_VERSION := 2021.1

.PHONY: help package templates bitstream ladder list clean check-board check-vivado
help:
	@sed -n '1,/^BOARDS/p' Makefile | grep '^#' | sed 's/^# \{0,1\}//'
	@echo "boards: $(BOARDS)"

check-board:
	@[ -n "$(BOARD)" ] || { echo "set BOARD= (one of: $(BOARDS))"; exit 2; }
	@[ -f boards/$(BOARD)/board.tcl ] || { echo "unknown BOARD=$(BOARD) (one of: $(BOARDS))"; exit 2; }
check-vivado:
	@v=$$(vivado -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+' | head -1); \
	[ "$$v" = "v$(VIVADO_VERSION)" ] || { echo "need Vivado $(VIVADO_VERSION) on PATH (found: $${v:-none}); source <Vivado>/settings64.sh"; exit 2; }

package: check-vivado
	$(MAKE) -C ip/src/uhd_ip package

templates: check-board check-vivado
	KIND=template FS=$(FS) MAXPAR=$(MAXPAR) JOBS=$(JOBS) SKIP_EXISTING=$(SKIP_EXISTING) flow/ladder.sh $(BOARD) $(STEP)
ladder: check-board check-vivado
	KIND= FS=$(FS) MAXPAR=$(MAXPAR) JOBS=$(JOBS) SKIP_EXISTING=$(SKIP_EXISTING) flow/ladder.sh $(BOARD) $(STEP)

# one build; only the bitstream (+ .hwh, reports) is kept: the Vivado project
# is deleted when Vivado exits, whatever the step or outcome (V49_KEEP_PROJ=1 keeps it)
bitstream: check-board check-vivado
	@[ -n "$(N)" ] || { echo "set N= (channel count)"; exit 2; }
	@mkdir -p build/$(BOARD); pf=$$(mktemp); \
	V49_PROJ_FILE=$$pf V49_IMPL_STRATEGY="$(STRATEGY)" vivado -mode batch -nojournal -nolog \
	    -source flow/build.tcl -tclargs $(BOARD) $(N) $(STEP) $(JOBS) "$(F)" "$(FS)"; rc=$$?; \
	p=$$(cat $$pf); rm -f $$pf; \
	if [ -n "$$p" ] && [ "$${V49_KEEP_PROJ:-0}" != 1 ]; then rm -rf build/$(BOARD)/$$p; echo "deleted build/$(BOARD)/$$p"; fi; \
	exit $$rc

list: check-board
	@printf "%-38s %-9s %s\n" build kind "status (built / TIMING-FAIL / - not built)"
	@grep -v '^#' boards/$(BOARD)/builds.txt | while read -r n f fs kind s; do \
	    [ -n "$$n" ] || continue; \
	    name=$(BOARD)_v49_$${n}ch_qsfp_f$${f}_fs$$(echo $$fs | tr . p); \
	    if [ -f build/$(BOARD)/bitstreams/$$name.bit ]; then st=built; \
	    elif [ -f build/$(BOARD)/bitstreams_timing_fail/$$name.bit ]; then st=TIMING-FAIL; else st=-; fi; \
	    printf "%-38s %-9s %s\n" $$name $$kind $$st; done

clean: check-board
	rm -rf build/$(BOARD)
