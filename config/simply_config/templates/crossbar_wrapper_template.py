# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description:
#   Generates hw/xilinx/rtl/wrappers/<bus>_crossbar_wrapper.sv: a module with the
#   port list of the Xilinx xlnx_<bus>_crossbar IP that instantiates either the IP
#   (XBAR_IMPL == XBAR_XILINX) or the in-tree crossbar RTL with the address map
#   of the bus baked in as parameters (XBAR_IMPL == XBAR_CUSTOM). Widths are
#   emitted as simplyv_pkg symbols (MBUS_DATA_WIDTH, ...), not baked-in numbers,
#   so the file is identical regardless of which core/XLEN last ran config_mbus/
#   config_pbus (MBUS_DATA_WIDTH tracks XLEN; PBUS widths are fixed at 32).

import os
from buses.bus import Bus
from .template import Template

AXI4_SI = [  # (direction, width, name) of the slave-side ports; master side mirrors them
	("input", "ID_WIDTH", "awid"), ("input", "ADDR_WIDTH", "awaddr"), ("input", "8", "awlen"), ("input", "3", "awsize"),
	("input", "2", "awburst"), ("input", "1", "awlock"), ("input", "4", "awcache"), ("input", "3", "awprot"),
	("input", "4", "awqos"), ("input", "1", "awvalid"), ("output", "1", "awready"),
	("input", "DATA_WIDTH", "wdata"), ("input", "STRB_WIDTH", "wstrb"), ("input", "1", "wlast"), ("input", "1", "wvalid"), ("output", "1", "wready"),
	("output", "ID_WIDTH", "bid"), ("output", "2", "bresp"), ("output", "1", "bvalid"), ("input", "1", "bready"),
	("input", "ID_WIDTH", "arid"), ("input", "ADDR_WIDTH", "araddr"), ("input", "8", "arlen"), ("input", "3", "arsize"),
	("input", "2", "arburst"), ("input", "1", "arlock"), ("input", "4", "arcache"), ("input", "3", "arprot"),
	("input", "4", "arqos"), ("input", "1", "arvalid"), ("output", "1", "arready"),
	("output", "ID_WIDTH", "rid"), ("output", "DATA_WIDTH", "rdata"), ("output", "2", "rresp"), ("output", "1", "rlast"), ("output", "1", "rvalid"), ("input", "1", "rready"),
]
AXI4_MI_EXTRA = [("output", "4", "awregion"), ("output", "4", "arregion")]   # IP master side only

AXILITE_SI = [
	("input", "ADDR_WIDTH", "awaddr"), ("input", "3", "awprot"), ("input", "1", "awvalid"), ("output", "1", "awready"),
	("input", "DATA_WIDTH", "wdata"), ("input", "STRB_WIDTH", "wstrb"), ("input", "1", "wvalid"), ("output", "1", "wready"),
	("output", "2", "bresp"), ("output", "1", "bvalid"), ("input", "1", "bready"),
	("input", "ADDR_WIDTH", "araddr"), ("input", "3", "arprot"), ("input", "1", "arvalid"), ("output", "1", "arready"),
	("output", "DATA_WIDTH", "rdata"), ("output", "2", "rresp"), ("output", "1", "rvalid"), ("input", "1", "rready"),
]

FLIP = {"input": "output", "output": "input"}


class Crossbar_Wrapper_Template(Template):

	_str_template: str = "{body}"

	def __init__(self, bus: Bus):
		self.bus = bus
		self.lite = (bus.PROTOCOL == "AXI4LITE")
		b = bus.FULL_NAME
		# Symbolic widths: simplyv_pkg localparams (MBUS_DATA_WIDTH tracks XLEN,
		# PBUS_DATA_WIDTH is a fixed 32), imported file-scope below so they are
		# visible in the ANSI port list itself. NUM_SI/NUM_MI/MI_BASE/ATOMICS_MASK
		# stay plain Python values: they come from the bus topology (the CSVs),
		# never from XLEN, so baking them in does not reintroduce the churn.
		self.widths = {
			"ADDR_WIDTH": f"{b}_ADDR_WIDTH", "DATA_WIDTH": f"{b}_DATA_WIDTH",
			"STRB_WIDTH": f"({b}_DATA_WIDTH/8)", "ID_WIDTH": f"{b}_ID_WIDTH",
		}

	def _port(self, direction: str, width: str, name: str, count: int, prefix: str) -> str:
		symbolic = width in self.widths
		w = self.widths.get(width, width)
		dim = f"[{count}-1:0]" + (f"[{w}-1:0]" if symbolic or int(w) > 1 else "")
		return f"    {direction:6} logic {dim:22} {prefix}_axi_{name}"

	def _ports(self) -> str:
		si = AXILITE_SI if self.lite else AXI4_SI
		lines = [self._port(d, w, n, self.bus.NUM_SI, "s") for d, w, n in si]
		mi = [(FLIP[d], w, n) for d, w, n in si] + ([] if self.lite else AXI4_MI_EXTRA)
		lines += [self._port(d, w, n, self.bus.NUM_MI, "m") for d, w, n in mi]
		return ",\n".join(lines)

	def _connections(self, custom: bool) -> str:
		si = AXILITE_SI if self.lite else AXI4_SI
		names = [f".s_axi_{n}" for _, _, n in si]
		if custom and not self.lite:
			names.append(".s_axi_awatop ( '0 )")   # SoC masters issue no AXI5 atomics
		names += [f".m_axi_{n}" for _, _, n in si]
		if not self.lite:
			names += [f".m_axi_{n}" for _, _, n in AXI4_MI_EXTRA]
		return ",\n            ".join(names)

	def _map(self):
		# Each child must have a single address range: Addr_Ranges can hold more
		# than one (ADDR_RANGES > 1 in the CSV), but the crossbar's MI_BASE/
		# MI_RANGE_BITS model exactly one range per master port. Taking the
		# first silently would misroute the others, so fail loudly instead.
		# Unsized hex literals (no bit-width prefix): Verilator rejects a named
		# parameter as a sized literal's width ("PBUS_ADDR_WIDTH'h..."), and the
		# assignment context (the MI_BASE_MAP element type) already sizes these.
		bases, bits = [], []
		for ranges in self.bus.get_ordered_children_ranges():
			items = list(ranges)
			if len(items) != 1:
				raise ValueError(
					f"{self.bus.FULL_NAME}: crossbar wrapper generator needs exactly one "
					f"address range per child, got {len(items)}")
			r = items[0]
			bases.append(f"'h{r.RANGE_BASE_ADDR:08x}")
			bits.append(str(r.RANGE_ADDR_WIDTH))
		return ", ".join(bases), ", ".join(bits)

	def _atomics_mask(self) -> str:
		names = self.bus.get_ordered_children_names()
		mem   = set(self.bus.get_memory_names())
		mask  = "".join("1" if n in mem else "0" for n in reversed(names))
		return f"{len(names)}'b{mask}"

	def _custom_inst(self) -> str:
		bases, bits = self._map()
		b = self.bus.FULL_NAME
		# Declared as named localparams rather than inlined '{...} literals in the
		# port-connection list: Verilator mis-sizes an inline assignment pattern
		# against a NUM_MI overridden in the same parameter list (elaboration
		# bug), the same reason simplyv_axi_xbar's own testbench pre-declares
		# MI_BASE/MI_BITS instead of passing literals directly.
		decl = (f"        localparam logic [{b}_ADDR_WIDTH-1:0] MI_BASE_MAP  [{self.bus.NUM_MI}] = '{{{bases}}};\n"
				f"        localparam int unsigned     MI_BITS_MAP  [{self.bus.NUM_MI}] = '{{{bits}}};\n")
		if self.lite:
			return (decl +
					f"        simplyv_axilite_xbar #(\n"
					f"            .NUM_SI ( {self.bus.NUM_SI} ), .NUM_MI ( {self.bus.NUM_MI} ),\n"
					f"            .DATA_WIDTH ( {b}_DATA_WIDTH ), .ADDR_WIDTH ( {b}_ADDR_WIDTH ),\n"
					f"            .MI_BASE  ( MI_BASE_MAP ),\n"
					f"            .MI_RANGE_BITS ( MI_BITS_MAP )\n"
					f"        ) xbar_u (\n            .aclk, .aresetn,\n            {self._connections(True)}\n        );")
		return (decl +
				f"        simplyv_axi_xbar #(\n"
				f"            .NUM_SI ( {self.bus.NUM_SI} ), .NUM_MI ( {self.bus.NUM_MI} ),\n"
				f"            .DATA_WIDTH ( {b}_DATA_WIDTH ), .ADDR_WIDTH ( {b}_ADDR_WIDTH ), .ID_WIDTH ( {b}_ID_WIDTH ),\n"
				f"            .MI_BASE  ( MI_BASE_MAP ),\n"
				f"            .MI_RANGE_BITS ( MI_BITS_MAP ),\n"
				f"            .ATOMICS_MASK ( {self._atomics_mask()} )\n"
				f"        ) xbar_u (\n            .aclk, .aresetn,\n            {self._connections(True)}\n        );")

	def get_params(self) -> dict[str, str]:
		bus  = self.bus.FULL_NAME.lower()
		body = (
			f"// This file is auto-generated with {os.path.basename(__file__)}\n"
			f"// {self.bus.FULL_NAME} crossbar: Xilinx axi_crossbar IP or the in-tree RTL, selected by XBAR_IMPL\n\n"
			f"import simplyv_pkg::*;\n\n"
			f"module {bus}_crossbar_wrapper (\n"
			f"    input  logic aclk,\n    input  logic aresetn,\n{self._ports()}\n);\n\n"
			f"    generate if (XBAR_IMPL == XBAR_CUSTOM) begin : custom\n{self._custom_inst()}\n"
			f"    end else begin : xilinx\n"
			f"        xlnx_{bus}_crossbar xbar_u (\n            .aclk, .aresetn,\n            {self._connections(False)}\n        );\n"
			f"    end endgenerate\n\nendmodule\n")
		return {"body": body}
