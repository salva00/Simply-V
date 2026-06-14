# Author: Salvatore Santoro				<sal.santoro@studenti.unina.it>
# Description:
#   Templates for the simulation flow (dual backend Verilator/xsim).
#   Sim_Defines_Template: mirror of hw/xilinx/synth/tcl/verilog_defines.tcl as a .svh,
#   so both backends consume the same macros the synth flow uses.
#   Sim_Addrmap_Template: SV package with the crossbar routing rules taken from the
#   same CSV data used to configure the Xilinx crossbar IPs (no hand-copied addrmaps).

import os
import re
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

	# Single source of truth for the simulation defines, as NAME=VALUE (or bare
	# NAME) pairs. Consumed both by the .svh emission (_init_defines) and by the
	# Verilator filelist construction (config_sim) - do NOT duplicate this list.
	def get_define_pairs(self) -> list[str]:
		pairs = []
		if self.profile == "hpc":
			pairs.append("HPC=1")
		elif self.profile == "embedded":
			pairs.append("EMBEDDED=1")
		else:
			raise ValueError(f"Unsupported profile {self.profile}")

		bus_names = set()
		for bus in self.system.buses:
			base = bus.FULL_NAME
			bus_names.add(base)
			pairs.append(f"{base}_NUM_SI={bus.NUM_SI}")
			pairs.append(f"{base}_NUM_MI={bus.NUM_MI}")
			pairs.append(f"{base}_ID_WIDTH={bus.ID_WIDTH}")
			if base == "MBUS":
				pairs.append(f"MBUS_DATA_WIDTH={bus.DATA_WIDTH}")
				pairs.append(f"MBUS_ADDR_WIDTH={bus.ADDR_WIDTH}")

		# HBUS is HPC-only and absent from self.buses on the embedded profile, but
		# simplyv_pkg.sv references HBUS_NUM_SI/HBUS_NUM_MI/HBUS_ID_WIDTH
		# unconditionally. The synth flow (verilog_defines.tcl) always emits them
		# (0 for embedded); mirror that here so the package elaborates.
		if "HBUS" not in bus_names:
			pairs.append("HBUS_NUM_SI=0")
			pairs.append("HBUS_NUM_MI=0")
			pairs.append("HBUS_ID_WIDTH=0")

		pairs.append(f"CORE_SELECTOR={self.system.CORE_SELECTOR}")
		pairs.append(f"MAIN_CLOCK_FREQ_MHZ={self.system.mbus.CLOCK_FREQUENCY}")

		# Clock domains (mirror of verilog_defines.tcl, which reads RANGE_CLOCK_DOMAINS
		# computed by config_xilinx_clock_domains: every domain macro is defined as itself)
		domains = ["MAIN_CLOCK_DOMAIN"]
		for n in self.system.mbus.get_nodes():
			if n.CLOCK_DOMAIN != self.system.mbus.CLOCK_DOMAIN:
				domains.append(n.FULL_NAME + "_HAS_CLOCK_DOMAIN")
		for d in domains:
			pairs.append(f"{d}={d}")
		return pairs

	def _init_defines(self) -> str:
		lines = []
		for pair in self.get_define_pairs():
			name, _, value = pair.partition("=")
			lines.append(f"`define {name} {value}" if value else f"`define {name}")
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


class Sim_Flist_Template(Template):
	# Verilator filelist (.f): defines, include dirs, then sources with all
	# SV packages listed before the modules that import them. Replaces the
	# old hand-maintained gen_embedded_filelist.sh.

	_str_template: str = textwrap.dedent("""\
	# This file is auto-generated with {this_file}
	{body}
	""")

	def __init__(self, defines, incdirs, prelude_files, rtl_roots,
				 exclude_patterns, extra_files):
		self.defines = defines
		self.incdirs = incdirs
		self.prelude_files = prelude_files
		self.rtl_roots = rtl_roots
		self.exclude_patterns = exclude_patterns
		self.extra_files = extra_files

	# Walk the rtl roots collecting .sv files, split into packages vs modules
	# (packages must be compiled first). Missing/empty roots are tolerated:
	# os.walk on a non-existent dir simply yields nothing.
	def _collect(self):
		pkg_re = re.compile(r"^\s*package\s+\w", re.M)
		excl_re = re.compile("|".join(self.exclude_patterns)) if self.exclude_patterns else None
		pkgs, mods = [], []
		for root in self.rtl_roots:
			for dirpath, _, files in sorted(os.walk(root)):
				for f in sorted(files):
					if not f.endswith(".sv"):
						continue
					path = os.path.join(dirpath, f)
					if excl_re and excl_re.search(path):
						continue
					with open(path, encoding="utf-8", errors="ignore") as fh:
						(pkgs if pkg_re.search(fh.read()) else mods).append(path)
		return pkgs, mods

	# Used by template.py in the write_to_file implementation
	def get_params(self) -> dict[str, str]:
		pkgs, mods = self._collect()
		lines  = [f"+define+{d}" for d in self.defines]
		lines += [f"+incdir+{i}" for i in self.incdirs]
		lines += self.prelude_files + pkgs + mods + self.extra_files
		return {"this_file": os.path.basename(__file__), "body": "\n".join(lines)}
