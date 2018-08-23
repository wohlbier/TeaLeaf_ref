#!/bin/bash
OMP_NUM_THREADS=1 mpirun --report-bindings --map-by core --bind-to core -n 32 ./tea_leaf 2>&1 | tee zzz_log_arm.txt
