# Author: Salvatore Santoro				<sal.santoro@studenti.unina.it>
# Description:
#   Templates for the simulation flow (dual backend Verilator/xsim).
#   Sim_Defines_Template: mirror of hw/xilinx/synth/tcl/verilog_defines.tcl as a .svh,
#   so both backends consume the same macros the synth flow uses.
#   Sim_Addrmap_Template: SV package with the crossbar routing rules taken from the
#   same CSV data used to configure the Xilinx crossbar IPs (no hand-copied addrmaps).

import os
import textwrap
from .template import Template


class Sim_Defines_Template(Template):

	_str_template: str = textwrap.dedent("""\
	// This file is auto-generated with {this_file}
	// Mirror of hw/xilinx/synth/tcl/verilog_defines.tcl for the simulation flow.
	`ifndef SIM_DEFINES_SVH
	`define SIM_DEFINES_SVH
	{defines}
	`endif // SIM_DEFINES_SVH
	""")

	def __init__(self, system, profile: str):
		self.system = system
		self.profile = profile

	def _init_defines(self) -> str:
		lines = []
		if self.profile == "hpc":
			lines.append("`define HPC 1")
		elif self.profile == "embedded":
			lines.append("`define EMBEDDED 1")
		else:
			raise ValueError(f"Unsupported profile {self.profile}")

		for bus in self.system.buses:
			base = bus.FULL_NAME
			lines.append(f"`define {base}_NUM_SI {bus.NUM_SI}")
			lines.append(f"`define {base}_NUM_MI {bus.NUM_MI}")
			lines.append(f"`define {base}_ID_WIDTH {bus.ID_WIDTH}")
			if base == "MBUS":
				lines.append(f"`define MBUS_DATA_WIDTH {bus.DATA_WIDTH}")
				lines.append(f"`define MBUS_ADDR_WIDTH {bus.ADDR_WIDTH}")

		lines.append(f"`define CORE_SELECTOR {self.system.CORE_SELECTOR}")
		lines.append(f"`define MAIN_CLOCK_FREQ_MHZ {self.system.mbus.CLOCK_FREQUENCY}")

		# Clock domains (mirror of verilog_defines.tcl, which reads RANGE_CLOCK_DOMAINS
		# computed by config_xilinx_clock_domains: every domain macro is defined as itself)
		domains = ["MAIN_CLOCK_DOMAIN"]
		for n in self.system.mbus.get_nodes():
			if n.CLOCK_DOMAIN != self.system.mbus.CLOCK_DOMAIN:
				domains.append(n.FULL_NAME + "_HAS_CLOCK_DOMAIN")
		for d in domains:
			lines.append(f"`define {d} {d}")
		return "\n".join(lines)

	# Used by template.py in the write_to_file implementation
	def get_params(self) -> dict[str, str]:
		return {
				"this_file": os.path.basename(__file__),
				"defines": self._init_defines()
				}


class Sim_Addrmap_Template(Template):

	_str_template: str = textwrap.dedent("""\
	// This file is auto-generated with {this_file}
	// Crossbar routing rules from the config CSVs - consumed by the Verilator shims.
	package sim_addrmap_pkg;
	{body}
	endpackage
	""")

	def __init__(self, buses: list):
		self.buses = buses

	def _init_body(self) -> str:
		chunks = []
		for bus in self.buses:
			base = bus.FULL_NAME
			names = bus.get_ordered_children_names()
			rules = []  # (base_addr, end_addr, mi_index, name)
			for mi_index, addr_ranges in enumerate(bus.get_ordered_children_ranges()):
				for addr_range in addr_ranges:
					start = addr_range.RANGE_BASE_ADDR
					end = start + (1 << addr_range.RANGE_ADDR_WIDTH)
					rules.append((start, end, mi_index, names[mi_index]))

			n = len(rules)
			starts = ", ".join(f"64'h{r[0]:016x}" for r in rules)
			ends   = ", ".join(f"64'h{r[1]:016x}" for r in rules)
			idxs   = ", ".join(str(r[2]) for r in rules)
			chunk_lines = [f"  // ---- {base} ----"]
			chunk_lines += [f"  // rule {i}: {r[3]} [{hex(r[0])}, {hex(r[1])})"
							for i, r in enumerate(rules)]
			chunk_lines.append(f"  localparam int unsigned {base}_NumRules = {n};")
			chunk_lines.append(f"  localparam longint unsigned {base}_RuleStart [{n}] = '{{{starts}}};")
			chunk_lines.append(f"  localparam longint unsigned {base}_RuleEnd   [{n}] = '{{{ends}}};")
			chunk_lines.append(f"  localparam int unsigned     {base}_RuleIdx   [{n}] = '{{{idxs}}};")
			chunks.append("\n".join(chunk_lines) + "\n")
		return "\n".join(chunks)

	# Used by template.py in the write_to_file implementation
	def get_params(self) -> dict[str, str]:
		return {
				"this_file": os.path.basename(__file__),
				"body": self._init_body()
				}
