# Author: Stefano Mercogliano <stefano.mercogliano@unina.it>
# Author: Salvatore Santoro <sal.santoro@studenti.unina.it>
# Author: Michele Giugliano <michele.giuglian2@studenti.unina.it>
# Description:
#   Makefile for AXI CDMA examples on Simply-V SoC.
# Usage:
#       make CDMA_EXAMPLE=simple
#       make CDMA_EXAMPLE=irq

################
# Program Name #
################

# Example selection
CDMA_EXAMPLE ?= simple
# Bind program name to example
PROGRAM_NAME = $(shell basename $$PWD)_$(CDMA_EXAMPLE)

#############
# Toolchain #
#############

#####################
# Paths and Folders #
#####################

SRC_DIR     = src
OBJ_DIR     = obj
INC_DIR     = inc
STARTUP_DIR = $(SW_SOC_ROOT)/common
LIB_DIR	    = $(SW_SOC_ROOT)/lib

#############
# Libraries #
#############

LIB_OBJ_TINYIO    = $(LIB_DIR)/tinyio/lib/tinyio.a
LIB_INC_TINYIO    = -I$(LIB_DIR)/tinyio/inc

LIB_OBJ_SIMPLYV  = $(LIB_DIR)/simplyv/lib/libsimplyv.a
LIB_INC_SIMPLYV   = -I$(LIB_DIR)/simplyv/inc

LIB_OBJ_LIST     = $(LIB_OBJ_TINYIO) $(LIB_OBJ_SIMPLYV)
LIB_INC_LIST     = $(LIB_INC_TINYIO) $(LIB_INC_SIMPLYV)

#############
# Toolchain #
#############

include $(SW_ROOT)/SoC/common/config.mk

# RV64 is fine here: the CDMA has 32-bit SRC/DST address regs and the driver writes
# LOWER_32_BITS of each pointer; the whole SoC memory map (BRAM, stack, buffers) lives
# below 0x10000, so the upper 32 bits are always zero and the truncation is lossless.
# Data width (32b) is independent of XLEN.

###########
# Targets #
###########

# Override object file
OBJS := $(OBJ_DIR)/$(CDMA_EXAMPLE)_main.o

# Use common targets
include $(SW_ROOT)/SoC/common/Makefile
