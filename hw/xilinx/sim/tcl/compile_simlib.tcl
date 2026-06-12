# Author: Vincenzo Maisto <vincenzo.maisto2@unina.it>
# Description: Compile Xilinx simulation libraries for xsim (vendor sim backend)

compile_simlib                                   \
    -simulator xsim                              \
    -family all                                  \
    -language all                                \
    -library all                                 \
    -dir "$::env(XILINX_SIMLIB_PATH)"            \
    -force
