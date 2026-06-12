# Tests for the sim templates (run from config/simply_config: python3.10 -m pytest tests/)
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from templates.sim_template import Sim_Defines_Template, Sim_Addrmap_Template
from buses.nonleafbus import NonLeafBus
from general.addr_range import Addr_Ranges


class FakeRange:
    def __init__(self, base, width):
        self.RANGE_BASE_ADDR = base
        self.RANGE_ADDR_WIDTH = width


class FakeBus:
    FULL_NAME = "MBUS"
    ADDR_WIDTH = 32
    DATA_WIDTH = 32
    ID_WIDTH = 4
    NUM_SI = 2
    NUM_MI = 2
    MASTER_NAMES = ["CORE", "DMA"]

    def get_ordered_children_ranges(self):
        return [[FakeRange(0x0, 16)], [FakeRange(0x20000, 17)]]

    def get_ordered_children_names(self):
        return ["BRAM", "PBUS"]


class FakeSystem:
    CORE_SELECTOR = "CORE_IBEX"
    XLEN = 32

    def __init__(self):
        self.buses = [FakeBus()]
        class _M:
            CLOCK_FREQUENCY = 100
            CLOCK_DOMAIN = "MBUS_100"
            def get_nodes(self):
                return []
        self.mbus = _M()


def test_defines_contains_profile_and_bus_macros():
    out = Sim_Defines_Template(FakeSystem(), "embedded").get_params()["defines"]
    assert "`define EMBEDDED 1" in out
    assert "`define MBUS_DATA_WIDTH 32" in out
    assert "`define MBUS_NUM_SI 2" in out
    assert "`define CORE_SELECTOR CORE_IBEX" in out


def test_addrmap_rules_match_csv_ranges():
    out = Sim_Addrmap_Template([FakeBus()]).get_params()["body"]
    assert "MBUS_NumRules" in out
    # base, end = base + 2**width, master index
    assert "64'h0000000000000000" in out          # BRAM base
    assert "64'h0000000000010000" in out          # BRAM end (2^16)
    assert "64'h0000000000020000" in out          # PBUS base
    assert "BRAM" in out and "PBUS" in out        # names as comments


class StubChild:
    # Minimal stand-in for a Peripheral/Bus child: only the two attributes
    # read by get_ordered_children_names/get_ordered_children_ranges,
    # using a REAL Addr_Ranges so the real sort key (__lt__ on base addr) applies
    def __init__(self, full_name, base, width):
        self.FULL_NAME = full_name
        self.assigned_addr_ranges = Addr_Ranges(full_name, [base], [width])


def test_real_nonleafbus_names_align_with_ranges():
    # Exercise the REAL NonLeafBus methods (not fakes). The full constructor
    # needs CSV-driven dicts and singletons, so build a skeleton and set only
    # the attributes those two methods actually read.
    bus = object.__new__(NonLeafBus)
    # Children deliberately listed OUT of base-address order so the test
    # fails if either method's sorting desyncs
    bus._children_peripherals = [
        StubChild("BRAM", 0x40000, 16),
        StubChild("UART", 0x0, 12),
    ]
    bus._children_buses = [StubChild("PBUS", 0x20000, 17)]
    bus.LOOPBACK = True
    bus.loopback_ranges = Addr_Ranges("MBUS", [0x10000], [16])

    names = bus.get_ordered_children_names()
    ranges = bus.get_ordered_children_ranges()

    assert len(names) == len(ranges)
    # Expected ascending base-address order:
    # UART (0x0), LOOPBACK (0x10000), PBUS (0x20000), BRAM (0x40000)
    assert names == ["UART", "LOOPBACK", "PBUS", "BRAM"]
    base_to_name = {0x0: "UART", 0x10000: "LOOPBACK",
                    0x20000: "PBUS", 0x40000: "BRAM"}
    for i, r in enumerate(ranges):
        # name at i must correspond to the child whose range is at i
        assert names[i] == base_to_name[r.get_base_addr()]
