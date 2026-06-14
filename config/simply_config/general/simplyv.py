# Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
# Author: Manuel Maddaluno <manuel.maddaluno@unina.it>
# Author: Stefano Mercogliano <stefano.mercogliano@unina.it>
# Author: Valerio Di Domenico <valerio.didomenico@unina.it>
# Author: Salvatore Santoro <sal.santoro@studenti.unina.it>
# Description: This class is the starting point for all the configuration targets
# the purpose of this class is:
# .1 Create the "MBUS" object (which is the root node of the buses and peripherals tree)
# .2 Launch all the configurations checks through the "init_configurations" method of MBUS
# .3 Launch all the file generations/modifications that will be needed from the "sw" and "hw"
#	 flows
#
# all the targets of the makefile in the "config root" are compatible with the simplyv methods
# through the "simply_config.py" file that launches the correct methods based on the makefile target that
# launched the whole configuration

import os
import re
from buses.nonleafbus import NonLeafBus
from .error import Conflict_Error, Unsupported_Value_Error
from templates.dump_template import Dump_Template
from templates.halheader_template import HALheader_Template
from templates.crossbar_template import Crossbar_Template
from templates.clocks_template import Clocks_Template
from templates.ld_template import Ld_Template
from peripherals.ddr4 import DDR4
from peripherals.bram import Bram
from templates.bus_interconnect_template import Bus_Interconnect_Template
from templates.sim_template import Sim_Defines_Template, Sim_Addrmap_Template, Sim_Flist_Template
from pathlib import Path
from factories.buses_factory import Buses_Factory
from peripherals.peripheral import Peripheral
from peripherals.uart import Uart
from .singleton import Singleton
from buses.mbus import MBus
from general.node import Node
from .logger import Logger
from .env import Env

class SimplyV(metaclass=Singleton):
	SUPPORTED_CORES = (
			"CORE_PICORV32",
			"CORE_CV32E40P",
			"CORE_IBEX",
			"CORE_MICROBLAZEV_RV32",
			"CORE_MICROBLAZEV_RV64",
			"CORE_DUAL_MICROBLAZEV_RV32",
			"CORE_CV64A6",
			"CORE_CV64A6_ARA"
		)

	def __init__(self, system_data: dict):
		self.buses_factory = Buses_Factory.get_instance()
		self.logger = Logger.get_instance()
		self.env = Env.get_instance()
		self.CORE_SELECTOR: str = system_data["CORE_SELECTOR"]
		self.MAIN_CLOCK_DOMAIN: str = system_data["MAIN_CLOCK_DOMAIN"]
		self.VIO_RESETN_DEFAULT: int = system_data["VIO_RESETN_DEFAULT"]
		self.XLEN: int = system_data["XLEN"]
		self.PHYSICAL_ADDR_WIDTH: int = system_data["PHYSICAL_ADDR_WIDTH"]
		self.BOOT_MEMORY_BLOCK: str = system_data["BOOT_MEMORY_BLOCK"]
		self.mbus: MBus

		main_clock_frqz = self.buses_factory.extract_clock_frequency(self.MAIN_CLOCK_DOMAIN)

		if (self.XLEN != 32) and (self.XLEN != 64):
			raise Unsupported_Value_Error("XLEN", self.XLEN, [32, 64])

		# CV64A6_ARA needs this particular check
		if ((main_clock_frqz > 50) and (self.CORE_SELECTOR == "CORE_CV64A6_ARA")):
			raise Conflict_Error("MAIN_CLOCK_DOMAIN", "CORE_SELECTOR", "CORE_CV64A6_ARA supports a maximum MAIN_CLOCK_DOMAIN frequency of 50 MHz.")

		# Check supported cores
		if (self.CORE_SELECTOR not in self.SUPPORTED_CORES):
			raise Unsupported_Value_Error("CORE_SELECTOR", self.CORE_SELECTOR, self.SUPPORTED_CORES)

		# MICROBLAZE needs this particular check
		if ("CORE_MICROBLAZEV" in self.CORE_SELECTOR):
			if (self.env.get_board() == "au280"):
				raise Conflict_Error("CORE_SELECTOR", "BOARD", "CORE_CV64A6_ARA CORE_MICROBLAZEV is not allowed when building for au280")

		# Create root node (MBUS)
		assigned_base_addr = [0]
		assigned_addr_width = [self.PHYSICAL_ADDR_WIDTH]
		clock_domain = self.MAIN_CLOCK_DOMAIN

		self.mbus = self.buses_factory.create_bus("MBUS", assigned_base_addr, assigned_addr_width, clock_domain,\
												axi_addr_width=self.PHYSICAL_ADDR_WIDTH, axi_data_width=self.XLEN)

		self.mbus.init_configurations()
		# get ALL the peripherals and buses on the configuration
		self.peripherals = self.mbus.get_peripherals(recursive=True)
		# Sort peripherals by base address range
		self.peripherals.sort(key=lambda p: p.assigned_addr_ranges)


		self.buses = [self.mbus]
		tree_buses = self.mbus.get_buses(recursive=True)
		if(tree_buses):
			self.buses.extend(tree_buses)

		# differentiate memories from normal devices
		self.devices: list[Peripheral] = []
		self.memories: list[Peripheral] = []

		for p in self.peripherals:
			if(p.IS_A_MEMORY):
				self.memories.append(p)
			else:
				self.devices.append(p)

		# Check BOOT_MEMORY
		m_names = [m.FULL_NAME for m in self.memories]
		if (self.BOOT_MEMORY_BLOCK not in m_names):
			raise Unsupported_Value_Error("BOOT_MEMORY_BLOCK", self.BOOT_MEMORY_BLOCK, m_names)

	# Create linker script used from the "sw" flow
	def create_linker_script(self, ld_root: str):
		template = Ld_Template(self.memories, self.BOOT_MEMORY_BLOCK)
		# Write Memory fragment
		template.write_to_file_memory(ld_root + "/memory.ld")
		# Write Sections fragment
		template.write_to_file_sections(ld_root + "/sections.ld")
		# Write Variables fragment
		template.write_to_file_variables(ld_root + "/variables.ld")


	# Dump reachability file containing all the main information about all the peripherals
	# in the configuration
	def dump_reachability(self, dump_file_name: str):
		dump_template = Dump_Template(self.peripherals)
		dump_template.write_to_file(dump_file_name)


	# Create HAL header used from the "sw" flow
	def create_hal_header(self, hal_header_file_name: str) -> None:
		nodes: list[Node] = []
		nodes.extend(self.buses)
		nodes.extend(self.peripherals)

		template = HALheader_Template(self.peripherals, self.devices, nodes, hal_header_file_name)
		template.write_to_file(hal_header_file_name)


	# Update the "sw" makefile with the corresponding XLEN selected
	def update_sw_makefile(self, sw_makefile: str) -> None:
		# read mk file
		sw_makefile_path = Path(sw_makefile)

		if not sw_makefile_path.is_file():
			raise FileNotFoundError(f"Missing file: {sw_makefile_path}")

		text = sw_makefile_path.read_text()

		# replace XLEN ?= <value>
		new_text = re.sub(
			r"XLEN\s*\?=.+",
			f"XLEN ?= {self.XLEN}",
			text
		)

		sw_makefile_path.write_text(new_text)


	# Generate all the configuration files of each bus:
	# SVINC files to use for crossbar ports declarations
	# config.tcl files to automatically configure the Xilinx Interconnect IP
	# CLOCK SVINC files (NonLeafBuses only) to configure the clock domains of the SOC
	def config_bus(self, target_bus: str, outputs: list[str]) -> bool:
		for bus in self.buses:
			if bus.FULL_NAME == target_bus.upper():
				crossbar_template = Crossbar_Template(bus)
				crossbar_template.write_to_file(outputs[0])
				bus_interconnect_template = Bus_Interconnect_Template(bus)
				bus_interconnect_template.write_to_file(outputs[1])
				# only NonLeafBus need to configure the clock svinc file
				if isinstance(bus, NonLeafBus):
					clock_template = Clocks_Template(bus)
					clock_template.write_to_file(outputs[2])
				return True

		# return false if the bus wasn't found
		return False


	# Units of the ibex cone compiled standalone for the Verilator backend
	SIM_IBEX_CONE_UNITS = (
			"custom_ibex",
			"custom_axi_from_mem",
			"custom_rv32_dbg_bscane",
			"custom_clint",
			"custom_rv_plic",
		)

	# Generate the simulation-flow artifacts (dual backend Verilator/xsim):
	# sim_defines.svh (mirror of the synth verilog defines),
	# sim_addrmap_pkg.sv (crossbar routing rules for the Verilator shims) and,
	# when flist_path/siminc_dir are given, the Verilator filelist plus the
	# sim-only include dir (renamed simplyv_axi.svh + $unit-scope prelude)
	def config_sim(self, defines_path: str, addrmap_path: str,
				   flist_path: str = None, siminc_dir: str = None) -> None:
		profile = os.environ.get("SIMPLYV_PROFILE")
		if profile is None:
			raise ValueError("SIMPLYV_PROFILE not set: source settings.sh first")

		defines_template = Sim_Defines_Template(self, profile)
		defines_template.write_to_file(defines_path)

		addrmap_template = Sim_Addrmap_Template(self.buses)
		addrmap_template.write_to_file(addrmap_path)

		if flist_path is None:
			return

		root = os.environ.get("SIMPLYV_ROOT_DIR")
		if root is None:
			raise ValueError("SIMPLYV_ROOT_DIR not set: source settings.sh first")

		# 1. Sim include dir: copy simplyv_axi.svh applying the sim-only token
		# rename axi_resp_t -> axi_resp_code_t (xsim sim-models already declare
		# an axi_resp_t of their own), copy simplyv_mem.svh unchanged
		os.makedirs(siminc_dir, exist_ok=True)
		headers_root = os.path.join(root, "hw", "xilinx", "rtl", "headers")
		axi_svh = Path(headers_root, "simplyv_axi.svh").read_text()
		axi_svh = re.sub(r"\baxi_resp_t\b", "axi_resp_code_t", axi_svh)
		Path(siminc_dir, "simplyv_axi.svh").write_text(axi_svh)
		Path(siminc_dir, "simplyv_mem.svh").write_text(
			Path(headers_root, "simplyv_mem.svh").read_text())

		# simplyv_pcie.svh: DEFINE_PCIE_PORTS is declared function-like `()` but
		# referenced without parens in sys_master.sv (`DEFINE_PCIE_PORTS,). Vivado
		# tolerates this; Verilator does not. Drop a sim-only copy with the macro
		# rewritten to object-like form. siminc is the first incdir, so this copy
		# shadows the real header at `include "simplyv_pcie.svh".
		pcie_svh = Path(headers_root, "simplyv_pcie.svh").read_text()
		pcie_svh = re.sub(r"`define\s+DEFINE_PCIE_PORTS\(\)",
						  "`define DEFINE_PCIE_PORTS", pcie_svh)
		Path(siminc_dir, "simplyv_pcie.svh").write_text(pcie_svh)

		# 2. Prelude: puts the $unit-scope typedefs in front of every compilation
		prelude_path = os.path.join(siminc_dir, "_prelude.sv")
		Path(prelude_path).write_text(
			"// Auto-generated: puts the $unit-scope typedefs in front of every compilation\n"
			'`include "simplyv_axi.svh"\n'
			'`include "simplyv_mem.svh"\n')

		# 3. IP-name-renamed wrappers. Each unit's top module lives in
		# hw/units/<unit>/custom_top_wrapper.sv and is named custom_top_wrapper,
		# but the Xilinx RTL instantiates it by IP name (custom_ibex, custom_clint,
		# ...). Emit one renamed copy per unit (custom_top_wrapper -> <unit>) so the
		# instantiations resolve and the wrappers don't collide.
		wrappers_dir = os.path.join(siminc_dir, "wrappers")
		os.makedirs(wrappers_dir, exist_ok=True)
		wrapper_files = []
		for unit in self.SIM_IBEX_CONE_UNITS:
			src = os.path.join(root, "hw", "units", unit, "custom_top_wrapper.sv")
			text = Path(src).read_text()
			text = re.sub(r"\bcustom_top_wrapper\b", unit, text)
			dest = os.path.join(wrappers_dir, f"{unit}.sv")
			Path(dest).write_text(text)
			wrapper_files.append(dest)

		# 4. Filelist: same defines as the .svh (single source of truth) plus
		# ASSERTS_OFF (sim-only: disables common_cells SVA Verilator can't parse)
		defines = defines_template.get_define_pairs() + ["ASSERTS_OFF"]

		unit_rtl_dirs = [os.path.join(root, "hw", "units", u, "rtl")
						 for u in self.SIM_IBEX_CONE_UNITS]
		xilinx_rtl = os.path.join(root, "hw", "xilinx", "rtl")

		incdirs = [siminc_dir]
		incdirs += unit_rtl_dirs
		incdirs += [
				xilinx_rtl,
				headers_root,
				os.path.join(root, "hw", "deps", "axi", "include"),
				os.path.join(root, "hw", "deps", "common_cells", "include"),
			]

		rtl_roots = [os.path.join(root, "hw", "xilinx", "sim", "generated")]
		rtl_roots += unit_rtl_dirs
		rtl_roots += [
				xilinx_rtl,
				os.path.join(root, "hw", "xilinx", "sim", "models", "common"),
				os.path.join(root, "hw", "xilinx", "sim", "models", "embedded"),
			]

		exclude_patterns = [
				r"pad_functional",
				r"reg_test\.sv$",
				r"axi_test\.sv$",
				r"hbus\.sv$",						# HPC-only bus
				r"hls_conv2d_wrapper\.sv$",			# HPC-only
				r"ddr4_channel_wrapper\.sv$",		# HPC-only
				r"virtual_uart\.sv$",				# HPC-only (ifdef HPC in uart_wrapper.sv)
				r"sim_defines\.svh$",				# header, not a compile unit
				r"_prelude\.sv$",					# already first via prelude_files
			]

		flist_template = Sim_Flist_Template(
				defines=defines,
				incdirs=incdirs,
				prelude_files=[prelude_path],
				rtl_roots=rtl_roots,
				exclude_patterns=exclude_patterns,
				extra_files=wrapper_files,
			)
		flist_template.write_to_file(flist_path)



	# Update the "hw" makefile with the corresponding "sys_targets" and "bus_targets" selected
	# used from Vivado
	def config_xilinx_makefile(self, xilinx_makefile: str) -> None:
		makefile_path = Path(xilinx_makefile)
		content = makefile_path.read_text()

		# System targets to replace
		sys_targets = ["CORE_SELECTOR", "VIO_RESETN_DEFAULT", "XLEN", "PHYSICAL_ADDR_WIDTH"]

		# Replace system targets with "self" values
		for t in sys_targets:
			# Example pattern: "XLEN ?= 32"
			pattern = rf"^{t}\s*\?=\s*.*$"
			replacement = f"{t} ?= {getattr(self, t)}" # getattr retrieve the corresponding "self" value
			content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

		# Bus targets
		bus_targets_suffixes = ["NUM_SI", "NUM_MI", "ID_WIDTH"]
		# MBUS has additional targets
		mbus_targets = [("MBUS_ADDR_WIDTH", "ADDR_WIDTH"), ("MBUS_DATA_WIDTH", "DATA_WIDTH")]

		for bus in self.buses:
			base = bus.FULL_NAME  # e.g. "MBUS", "PBUS", "HBUS"
			for suffix in bus_targets_suffixes:
				target = base + "_" + suffix
				# Example pattern: "MBUS_NUM_SI ?= 5"
				pattern = rf"^{target}\s*\?=\s*.*$"
				replacement = f"{target} ?= {getattr(bus, suffix)}" # getattr retrieve the corresponding "bus" value
				content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

			if (base == "MBUS"):
				for target, name in mbus_targets:
					# Example pattern: "MBUS_ADDR_WIDTH ?= 32" where "32" is mbus.ADDR_WIDTH parameter
					# Example pattern: "MBUS_ADDR_WIDTH ?= 32" where "32" is mbus.DATA_WIDTH parameter
					pattern = rf"^{target}\s*\?=\s*.*$"
					replacement = f"{target} ?= {getattr(bus, name)}"
					content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

		makefile_path.write_text(content)



	# Update the "hw" makefile with the "HAS_CLOCK_DOMAIN" values, used to conditionally istantiate
	# clock converters (at the rtl level) in order to adapt different clock domains
	def config_xilinx_clock_domains(self, file_name: str) -> None:
		children_nodes = self.mbus.get_nodes()
		prefix = "_HAS_CLOCK_DOMAIN"
		makefile_variable = ["MAIN_CLOCK_DOMAIN"]

		# construct clock domain list
		for n in children_nodes:
			if n.CLOCK_DOMAIN != self.mbus.CLOCK_DOMAIN:
				makefile_variable.append(n.FULL_NAME + prefix)

		makefile_variable_str = " ".join(makefile_variable)

		output_mk_file = Path(file_name)
		content = output_mk_file.read_text()

		# Replace RANGE_CLOCK_DOMAINS
		pattern_range = rf"^RANGE_CLOCK_DOMAINS\s*\?=\s*.*$"
		replacement_range = f"RANGE_CLOCK_DOMAINS ?= {makefile_variable_str}"
		content = re.sub(pattern_range, replacement_range, content, flags=re.MULTILINE)

		# Replace MAIN_CLOCK_FREQ_MHZ
		pattern_freq = rf"^MAIN_CLOCK_FREQ_MHZ\s*\?=\s*.*$"
		replacement_freq = f"MAIN_CLOCK_FREQ_MHZ ?= {self.mbus.CLOCK_FREQUENCY}"
		content = re.sub(pattern_freq, replacement_freq, content, flags=re.MULTILINE)

		output_mk_file.write_text(content)

	# Trigger specific peripherals IPs configurations
	# NOTE: this could be handled with a dictiorary of {peripheral, paths},
	#		rather than this unstructured list of paths
	def config_peripherals_ips(self, paths: list[str]) -> None:
		for p in self.peripherals:
			# DDR4CHx
			if isinstance(p, DDR4):
				p.config_ip(paths[0])
			# BRAM
			if isinstance(p, Bram):
				# divide for XLEN_bytes
				xlen_bytes = int(self.XLEN / 8)
				p.config_ip(paths[1], xlen_bytes=xlen_bytes)
			# UART
			if isinstance(p, Uart):
			 	p.config_ip(paths[2])
