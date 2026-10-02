# Author: Salvatore Bramante <salvatore.bramante@yahoo.it>
# Description: Compile Xilinx simulation libraries for xsim

compile_simlib                                   \
    -simulator xsim                              \
    -family all                                  \
    -language all                                \
    -library all                                 \
    -dir "$::env(XILINX_SIMLIB_PATH)"            \
    -force
