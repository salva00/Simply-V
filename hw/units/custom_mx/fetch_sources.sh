#!/bin/bash
# Author: Salvatore Bramante <salvatorebramantewpn@gmail.com>
# Description: downloads the UPV/GAP VC0 (MX) sources and flattens them into rtl/

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
IP_NAME=$( basename $(dirname $( realpath ${BASH_SOURCE[0]} ) ))

mkdir -p rtl

GIT_URL=https://github.com/rattokiller/MX-prova.git
GIT_BRANCH=main
GIT_COMMIT=304b03a
CLONE_DIR=mx_src
printf "${YELLOW}[FETCH_SOURCES $IP_NAME] Cloning source repository${NC}\n"
git clone ${GIT_URL} -b ${GIT_BRANCH} ${CLONE_DIR}
cd ${CLONE_DIR}; git checkout ${GIT_COMMIT}; cd ..

FLIST="$PWD/assets/flist"
LOOKUP_DIR="$PWD/mx_src/prova/vc0"
RTL_DIR="$PWD/rtl"

printf "${YELLOW}[FETCH_SOURCES $IP_NAME] Copy all sources into rtl${NC}\n"
while IFS= read -r filename; do
    [ -z "$filename" ] && continue
    case "$filename" in \#*) continue;; esac
    filepath=$(find "$LOOKUP_DIR" -type f -name "$filename" 2>/dev/null | head -n 1)
    if [ -n "$filepath" ]; then
        cp "$filepath" "$RTL_DIR/"
    else
        printf "${RED}[FETCH_SOURCES $IP_NAME] Error: $filename not found${NC}\n"; exit 1
    fi
done < "$FLIST"

printf "${YELLOW}[FETCH_SOURCES $IP_NAME] Copy bridge into rtl${NC}\n"
cp "$PWD/mx_mem_bridge.sv" "$RTL_DIR/"

# FPU.v instantiates module MC_OPERATOR, which upstream declares in
# MC_OPERATOR_sys.v (filename != module name). Verilator resolves uninstantiated
# .v leaves by filename==module auto-lookup, so rename the vendored file to match
# the module name. (We deliberately vendor only the _sys variant; renaming avoids
# a duplicate-module clash with the upstream MC_OPERATOR.v we do NOT vendor.)
mv "$RTL_DIR/MC_OPERATOR_sys.v" "$RTL_DIR/MC_OPERATOR.v"

printf "${YELLOW}[FETCH_SOURCES $IP_NAME] Applying local patches${NC}\n"
patch -p1 -d rtl < "$PWD/assets/patches/l1d_uncached.patch"
patch -p1 -d rtl < "$PWD/assets/patches/memaccess_nca_word.patch"
patch -p1 -d rtl < "$PWD/assets/patches/core_irq.patch"

printf "${GREEN}[FETCH_SOURCES $IP_NAME] Completed${NC}\n"
