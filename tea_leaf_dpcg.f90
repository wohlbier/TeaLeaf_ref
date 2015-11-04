
MODULE tea_leaf_dpcg_module

  USE tea_leaf_dpcg_kernel_module
  USE tea_leaf_cheby_module
  USE tea_leaf_common_module

  USE definitions_module
  use global_mpi_module
  USE update_halo_module

  IMPLICIT NONE

  INTEGER, PARAMETER :: coarse_solve_max_iters=200

  LOGICAL :: inner_use_ppcg
  REAL(KIND=8), DIMENSION(coarse_solve_max_iters) :: inner_cg_alphas, inner_cg_betas
  REAL(KIND=8), DIMENSION(coarse_solve_max_iters) :: inner_ch_alphas, inner_ch_betas
  REAL(KIND=8) :: eigmin, eigmax, theta

CONTAINS

SUBROUTINE tea_leaf_dpcg_init_x0()

  IMPLICIT NONE

  INTEGER :: t, err
  INTEGER :: it_count, info

  ! done before
  !CALL tea_leaf_calc_residual()

  CALL tea_leaf_dpcg_coarsen_matrix()

  CALL tea_leaf_dpcg_restrict_ZT()

  ! just use CG on the first one
  inner_use_ppcg = .FALSE.

  ! FIXME if initial residual is very small, not enough steps to provide an
  ! accurate guess for the eigenvalues (if diagonal scaling on the coarse
  ! grid correction is disablee). Need to run CG for at least ~30 steps to
  ! get a good guess

  CALL tea_leaf_dpcg_local_solve(   &
      chunk%def%x_min, &
      chunk%def%x_max,                                  &
      chunk%def%y_min,                                  &
      chunk%def%y_max,                                  &
      halo_exchange_depth,                                  &
      chunk%def%t2,                               &
      chunk%def%t1,                               &
      chunk%def%def_Kx, &
      chunk%def%def_Ky, &
      chunk%def%def_di, &
      chunk%def%def_p,                               &
      chunk%def%def_r,                               &
      chunk%def%def_Mi,                               &
      chunk%def%def_w,                               &
      chunk%def%def_z, &
      chunk%def%def_sd, &
      eps, &
      coarse_solve_max_iters,                          &
      it_count,         &
      0.0_8,            &
      inner_use_ppcg,       &
      inner_cg_alphas, inner_cg_betas,      &
      inner_ch_alphas, inner_ch_betas       &
      )

  ! add back onto the fine grid
  CALL tea_leaf_dpcg_add_z()

  ! for all subsequent steps, use ppcg
  !inner_use_ppcg = .TRUE.

  !CALL tea_calc_eigenvalues(inner_cg_alphas, inner_cg_betas, eigmin, eigmax, &
  !    max_iters, it_count, info)

  ! With jacobi preconditioner on
  eigmin = 0.01_8
  eigmax = 2.0_8

  IF (info .NE. 0) CALL report_error('tea_leaf_dpcg_init_x0', 'Error in calculating eigenvalues')

  CALL tea_calc_ch_coefs(inner_ch_alphas, inner_ch_betas, eigmin, eigmax, &
      theta, it_count)

  ! calc residual again, and do initial solve
  CALL tea_leaf_calc_residual()

  CALL tea_leaf_dpcg_setup_and_solve_E()

  CALL tea_leaf_dpcg_init_p()

END SUBROUTINE tea_leaf_dpcg_init_x0

SUBROUTINE tea_leaf_dpcg_coarsen_matrix()

  IMPLICIT NONE
  INTEGER :: t, err

  REAL(KIND=8) :: kx_local, ky_local, tile_size

  chunk%def%def_Kx = 0.0_8
  chunk%def%def_Ky = 0.0_8
  chunk%def%def_di = 0.0_8

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(Kx_local, Ky_local, tile_size)
!$OMP DO
    DO t=1,tiles_per_task
      kx_local = 0.0_8
      ky_local = 0.0_8

      CALL tea_leaf_dpcg_coarsen_matrix_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_Kx,                              &
          chunk%tiles(t)%field%vector_Ky,                              &
          kx_local,                             &
          ky_local,                             &
          chunk%tiles(t)%field%rx,  &
          chunk%tiles(t)%field%ry)

      chunk%def%def_kx(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = kx_local
      chunk%def%def_ky(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = ky_local

      tile_size = chunk%tiles(t)%x_cells*chunk%tiles(t)%y_cells

      chunk%def%def_di(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = tile_size
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

  CALL MPI_Allreduce(MPI_IN_PLACE, chunk%def%def_kx, size(chunk%def%def_kx), MPI_DOUBLE_PRECISION, MPI_SUM, mpi_cart_comm, err)
  CALL MPI_Allreduce(MPI_IN_PLACE, chunk%def%def_ky, size(chunk%def%def_ky), MPI_DOUBLE_PRECISION, MPI_SUM, mpi_cart_comm, err)
  CALL MPI_Allreduce(MPI_IN_PLACE, chunk%def%def_di, size(chunk%def%def_di), MPI_DOUBLE_PRECISION, MPI_SUM, mpi_cart_comm, err)

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      chunk%def%def_di(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = &
          chunk%def%def_di(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) + &
          chunk%def%def_kx(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) + &
          chunk%def%def_ky(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) + &
          chunk%def%def_kx(chunk%tiles(t)%def_tile_coords(1) + 1, chunk%tiles(t)%def_tile_coords(2)) + &
          chunk%def%def_ky(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2) + 1)
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_coarsen_matrix

SUBROUTINE tea_leaf_dpcg_setup_and_solve_E

  IMPLICIT NONE

  INTEGER :: err
  INTEGER :: it_count

  CALL tea_leaf_dpcg_matmul_ZTA()
  CALL tea_leaf_dpcg_restrict_ZT()

  CALL tea_leaf_dpcg_local_solve(   &
      chunk%def%x_min, &
      chunk%def%x_max,                                  &
      chunk%def%y_min,                                  &
      chunk%def%y_max,                                  &
      halo_exchange_depth,                                  &
      chunk%def%t2,                               &
      chunk%def%t1,                               &
      chunk%def%def_Kx, &
      chunk%def%def_Ky, &
      chunk%def%def_di, &
      chunk%def%def_p,                               &
      chunk%def%def_r,                               &
      chunk%def%def_Mi,                               &
      chunk%def%def_w,                               &
      chunk%def%def_z, &
      chunk%def%def_sd, &
      eps, &
      coarse_solve_max_iters,                          &
      it_count,         &
      theta,            &
      inner_use_ppcg,       &
      inner_cg_alphas, inner_cg_betas,      &
      inner_ch_alphas, inner_ch_betas       &
      )

  CALL tea_leaf_dpcg_prolong_Z()

END SUBROUTINE tea_leaf_dpcg_setup_and_solve_E

SUBROUTINE tea_leaf_dpcg_matmul_ZTA()

  IMPLICIT NONE

  INTEGER :: t, err
  REAL(KIND=8) :: ztaz

  INTEGER :: fields(NUM_FIELDS)
  fields(field_z) = 1

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(ztaz)
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_solve_z_kernel(chunk%tiles(t)%field%x_min, &
          chunk%tiles(t)%field%x_max,                                  &
          chunk%tiles(t)%field%y_min,                                  &
          chunk%tiles(t)%field%y_max,                                  &
          halo_exchange_depth,                                  &
          chunk%tiles(t)%field%vector_r,                               &
          chunk%tiles(t)%field%vector_z,                               &
          chunk%tiles(t)%field%vector_Kx,                              &
          chunk%tiles(t)%field%vector_Ky,                              &
          chunk%tiles(t)%field%vector_Mi,                              &
          chunk%tiles(t)%field%tri_cp,   &
          chunk%tiles(t)%field%tri_bfp,    &
          chunk%tiles(t)%field%rx,  &
          chunk%tiles(t)%field%ry,  &
          tl_preconditioner_type)
    ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL
  ENDIF

  chunk%def%t1 = 0

  call update_halo(fields, 1)

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(ztaz)
!$OMP DO
    DO t=1,tiles_per_task
      ztaz = 0.0_8

      CALL tea_leaf_dpcg_matmul_ZTA_kernel(chunk%tiles(t)%field%x_min, &
          chunk%tiles(t)%field%x_max,                                  &
          chunk%tiles(t)%field%y_min,                                  &
          chunk%tiles(t)%field%y_max,                                  &
          halo_exchange_depth,                                  &
          chunk%tiles(t)%field%vector_z,                               &
          chunk%tiles(t)%field%vector_Kx,                              &
          chunk%tiles(t)%field%vector_Ky,                              &
          chunk%tiles(t)%field%rx,  &
          chunk%tiles(t)%field%ry,  &
          ztaz,                     &
          tl_preconditioner_type)

      ! write back into the GLOBAL vector
      chunk%def%t1(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = ztaz
    ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL
  ENDIF

  CALL MPI_Allreduce(MPI_IN_PLACE, chunk%def%t1, size(chunk%def%t1), MPI_DOUBLE_PRECISION, MPI_SUM, mpi_cart_comm, err)

END SUBROUTINE tea_leaf_dpcg_matmul_ZTA

SUBROUTINE tea_leaf_dpcg_restrict_ZT()

  IMPLICIT NONE
  INTEGER :: t, err
  REAL(KIND=8) :: ZTr

  chunk%def%t2 = 0

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(ZTr)
!$OMP DO
    DO t=1,tiles_per_task
      ztr = 0.0_8

      CALL tea_leaf_dpcg_restrict_ZT_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_r,    &
          ztr)

      chunk%def%t2(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)) = ztr
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

  CALL MPI_Allreduce(MPI_IN_PLACE, chunk%def%t2, size(chunk%def%t2), MPI_DOUBLE_PRECISION, MPI_SUM, mpi_cart_comm, err)

END SUBROUTINE tea_leaf_dpcg_restrict_ZT

SUBROUTINE tea_leaf_dpcg_prolong_Z()

  IMPLICIT NONE

  INTEGER :: t

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_prolong_Z_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_z, &
          chunk%def%t2(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)))
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_prolong_Z

SUBROUTINE tea_leaf_dpcg_init_p()

  IMPLICIT NONE

  INTEGER :: t

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_init_p_kernel(chunk%tiles(t)%field%x_min,&
          chunk%tiles(t)%field%x_max,                                         &
          chunk%tiles(t)%field%y_min,                                         &
          chunk%tiles(t)%field%y_max,                                         &
          halo_exchange_depth,                                         &
          chunk%tiles(t)%field%vector_p,                                      &
          chunk%tiles(t)%field%vector_z)
    ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_init_p

SUBROUTINE tea_leaf_dpcg_store_r()

  IMPLICIT NONE
  INTEGER :: t

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_store_r_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_r, &
          chunk%tiles(t)%field%vector_r_m1 )
      ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_store_r

SUBROUTINE tea_leaf_dpcg_calc_rrn(rrn)

  IMPLICIT NONE
  INTEGER :: t
  REAL(KIND=8) :: rrn, tile_rrn

  rrn = 0.0_8

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(tile_rrn)
!$OMP DO REDUCTION(+:rrn)
    DO t=1,tiles_per_task
      tile_rrn = 0.0_8

      CALL tea_leaf_dpcg_calc_rrn_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_r, &
          chunk%tiles(t)%field%vector_r_m1, &
          chunk%tiles(t)%field%vector_z, &
          tile_rrn)

      rrn = rrn + tile_rrn
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_calc_rrn

SUBROUTINE tea_leaf_dpcg_calc_p(beta)

  IMPLICIT NONE
  INTEGER :: t
  REAL(KIND=8) :: beta

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_calc_p_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%vector_p, &
          chunk%tiles(t)%field%vector_r, &
          chunk%tiles(t)%field%vector_z, &
          chunk%tiles(t)%field%vector_Kx,                              &
          chunk%tiles(t)%field%vector_Ky,                              &
          chunk%tiles(t)%field%tri_cp,   &
          chunk%tiles(t)%field%tri_bfp,    &
          chunk%tiles(t)%field%rx,  &
          chunk%tiles(t)%field%ry,  &
          beta, tl_preconditioner_type )
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_calc_p

SUBROUTINE tea_leaf_dpcg_calc_zrnorm(rro)

  IMPLICIT NONE

  INTEGER :: t
  REAL(KIND=8) :: rro, tile_rro

  rro = 0.0_8

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL PRIVATE(tile_rro)
!$OMP DO REDUCTION(+:rro)
    DO t=1,tiles_per_task
      tile_rro = 0.0_8

      CALL tea_leaf_dpcg_calc_zrnorm_kernel(chunk%tiles(t)%field%x_min, &
            chunk%tiles(t)%field%x_max,                           &
            chunk%tiles(t)%field%y_min,                           &
            chunk%tiles(t)%field%y_max,                           &
            halo_exchange_depth,                           &
            chunk%tiles(t)%field%vector_z,                        &
            chunk%tiles(t)%field%vector_r,                        &
            tl_preconditioner_type, tile_rro)

      rro = rro + tile_rro
    ENDDO
!$OMP END DO NOWAIT
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_calc_zrnorm

SUBROUTINE tea_leaf_dpcg_add_z()

  IMPLICIT NONE
  INTEGER :: t

  IF (use_fortran_kernels) THEN
!$OMP PARALLEL
!$OMP DO
    DO t=1,tiles_per_task
      CALL tea_leaf_dpcg_add_z_kernel(chunk%tiles(t)%field%x_min,    &
          chunk%tiles(t)%field%x_max,           &
          chunk%tiles(t)%field%y_min,           &
          chunk%tiles(t)%field%y_max,           &
          halo_exchange_depth,                  &
          chunk%tiles(t)%field%u, &
          chunk%def%t2(chunk%tiles(t)%def_tile_coords(1), chunk%tiles(t)%def_tile_coords(2)))
    ENDDO
!$OMP END DO
!$OMP END PARALLEL
  ENDIF

END SUBROUTINE tea_leaf_dpcg_add_z

END MODULE tea_leaf_dpcg_module

