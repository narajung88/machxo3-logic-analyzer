# Simulation targets (Icarus Verilog). The Diamond build is done in the GUI;
# see docs/GUIDE.md.
#
#   make sim       12 MHz build testbench   (sim/tb_la.v)
#   make sim100    100 MHz build testbench  (sim/tb_la_100.v, simulated PLL)
#   make test      both; fails unless both print ALL TESTS PASSED
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp
BUILD    := build

CORE := rtl/la_core.v rtl/la_capture.v rtl/sump_cmd.v rtl/sump_resp.v \
        rtl/test_gen.v rtl/uart_rx.v rtl/uart_tx.v

.PHONY: sim sim100 test clean

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/tb_la: sim/tb_la.v rtl/la_top.v $(CORE) | $(BUILD)
	$(IVERILOG) -g2005 -o $@ sim/tb_la.v rtl/la_top.v $(CORE)

$(BUILD)/tb_la_100: sim/tb_la_100.v sim/pll_100_sim.v rtl/la_top_100.v $(CORE) | $(BUILD)
	$(IVERILOG) -g2005 -o $@ sim/tb_la_100.v sim/pll_100_sim.v rtl/la_top_100.v $(CORE)

sim: $(BUILD)/tb_la
	$(VVP) -n $< | tee $(BUILD)/tb_la.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/tb_la.log

sim100: $(BUILD)/tb_la_100
	$(VVP) -n $< | tee $(BUILD)/tb_la_100.log
	@grep -q "ALL TESTS PASSED" $(BUILD)/tb_la_100.log

test: sim sim100

clean:
	rm -rf $(BUILD)
