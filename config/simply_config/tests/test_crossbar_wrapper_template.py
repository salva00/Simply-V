# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: tests for the crossbar wrapper generator (run from config/simply_config: python -m pytest tests/)
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

from templates.crossbar_wrapper_template import Crossbar_Wrapper_Template
from general.addr_range import Addr_Ranges


class FakeMbus:
    FULL_NAME = "MBUS"; PROTOCOL = "AXI4"; ADDR_WIDTH = 32; DATA_WIDTH = 32; ID_WIDTH = 5; NUM_SI = 5; NUM_MI = 3
    def get_ordered_children_ranges(self):
        return [Addr_Ranges("BRAM_0", [0x0], [16]), Addr_Ranges("PBUS", [0x20000], [16]),
                Addr_Ranges("PLIC", [0x4000000], [26])]
    def get_ordered_children_names(self):
        return ["BRAM_0", "PBUS", "PLIC"]
    def get_memory_names(self):
        return ["BRAM_0"]


class FakePbus(FakeMbus):
    FULL_NAME = "PBUS"; PROTOCOL = "AXI4LITE"; ID_WIDTH = 0; NUM_SI = 1; NUM_MI = 2
    def get_ordered_children_ranges(self):
        return [Addr_Ranges("UART", [0x20000], [4]), Addr_Ranges("GPIOOUT", [0x20200], [9])]
    def get_ordered_children_names(self):
        return ["UART", "GPIOOUT"]
    def get_memory_names(self):
        return []


class FakeMultiRange(FakeMbus):
    # A child with ADDR_RANGES > 1: Addr_Ranges holding two Addr_Range entries.
    def get_ordered_children_ranges(self):
        return [Addr_Ranges("BRAM_0", [0x0, 0x100], [4, 4]), Addr_Ranges("PBUS", [0x20000], [16]),
                Addr_Ranges("PLIC", [0x4000000], [26])]


def test_mbus_wrapper_tracks_xlen_defines_not_baked_widths():
    out = Crossbar_Wrapper_Template(FakeMbus()).get_params()["body"]
    assert "module mbus_crossbar_wrapper" in out
    assert "simplyv_axi_xbar #(" in out and "xlnx_mbus_crossbar xbar_u" in out
    # Widths come from simplyv_pkg symbols (MBUS_DATA_WIDTH tracks XLEN), never
    # from a Python int baked in at generation time: this is what makes the
    # file identical across CORE_SELECTOR/XLEN.
    assert "import simplyv_pkg::*;" in out
    assert "[MBUS_ID_WIDTH-1:0]" in out
    assert "[MBUS_DATA_WIDTH-1:0]" in out
    assert "[(MBUS_DATA_WIDTH/8)-1:0]" in out
    assert ".DATA_WIDTH ( MBUS_DATA_WIDTH ), .ADDR_WIDTH ( MBUS_ADDR_WIDTH ), .ID_WIDTH ( MBUS_ID_WIDTH )" in out
    assert "MI_BASE_MAP  [3] = '{'h00000000, 'h00020000, 'h04000000}" in out
    assert "MI_BITS_MAP  [3] = '{16, 16, 26}" in out
    assert ".MI_BASE  ( MI_BASE_MAP )" in out
    assert ".MI_RANGE_BITS ( MI_BITS_MAP )" in out
    assert ".ATOMICS_MASK ( 3'b001 )" in out            # BRAM_0 is MI index 0
    assert "XBAR_IMPL == XBAR_CUSTOM" in out
    assert ".s_axi_awatop ( '0 )" in out                 # the SoC buses carry no ATOP


def test_pbus_wrapper_is_axilite_with_fixed_32bit_widths():
    out = Crossbar_Wrapper_Template(FakePbus()).get_params()["body"]
    assert "module pbus_crossbar_wrapper" in out
    assert "simplyv_axilite_xbar #(" in out and "xlnx_pbus_crossbar xbar_u" in out
    assert "awid" not in out
    assert "[PBUS_DATA_WIDTH-1:0]" in out
    assert ".DATA_WIDTH ( PBUS_DATA_WIDTH ), .ADDR_WIDTH ( PBUS_ADDR_WIDTH )" in out


def test_multi_range_child_raises_instead_of_silently_taking_the_first():
    with pytest.raises(ValueError, match="exactly one address range"):
        Crossbar_Wrapper_Template(FakeMultiRange()).get_params()
