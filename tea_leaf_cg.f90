!cROWn Copyright 2014 AWE.
!
! This file is part of TeaLeaf.
!
! TeaLeaf is free software: you can redistribute it and/or modify it under
! the terms of the GNU General Public License as published by the
! Free Software Foundation, either version 3 of the License, or (at your option)
! any later version.
!
! TeaLeaf is distributed in the hope that it will be useful, but
! WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
! details.
!
! You should have received a copy of the GNU General Public License along with
! TeaLeaf. If not, see http://www.gnu.org/licenses/.

!>  @brief Fortran heat conduction kernel
!>  @author Michael Boulton, Wayne Gaudin
!>  @details Implicitly calculates the change in temperature using CG method

MODULE tea_leaf_kernel_cg_module

IMPLICIT NONE

    integer, parameter::stride = 4

CONTAINS

SUBROUTINE tea_leaf_kernel_init_cg_fortran(x_min,  &
                           x_max,                  &
                           y_min,                  &
                           y_max,                  &
                           density,                &
                           energy,                 &
                           u,                      &
                           p,                      &
                           r,                      &
                           Mi,                     &
                           w,                      &
                           z,                      &
                           Kx,                     &
                           Ky,                     &
                           cp,                     &
                           bfp,                     &
                           dp,                     &
                           rx,                     &
                           ry,                     &
                           rro,                    &
                           coef,                   &
                           preconditioner_on)

  IMPLICIT NONE

  LOGICAL :: preconditioner_on
  INTEGER(KIND=4):: x_min,x_max,y_min,y_max
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: density
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: energy
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: u
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: p
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: r
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Mi
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: w
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: z
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Kx
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Ky

  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: cp, dp, bfp

  INTEGER(KIND=4) :: coef
  INTEGER(KIND=4) :: j,k,n,s,bottom,top,ko

  REAL(kind=8) :: rro
  REAL(KIND=8) ::  rx, ry

   INTEGER         ::            CONDUCTIVITY        = 1 &
                                ,RECIP_CONDUCTIVITY  = 2

  rro = 0.0_8
  p = 0.0_8
  cp = 0.0_8
  dp = 0.0_8
  bfp = 0.0_8

  if (mod(y_max, stride) .ne. 0) then
    write(0,*) "Preconditioner turned off - does not divide evenly"
    preconditioner_on = .false.
  endif

#define COEF_A (-Ky(j, k)*ry)
#define COEF_B (1.0_8 + ry*(Ky(j, k+1) + Ky(j, k)) + rx*(Kx(j+1, k) + Kx(j, k)))
#define COEF_C (-Ky(j, k+1)*ry)

!$OMP PARALLEL
  IF (preconditioner_on) then
!$OMP DO private(j, bottom, top, ko, k)
    DO ko=y_min,y_max,stride

      bottom = ko
      top = ko + stride - 1

      do j=x_min, x_max
        k = bottom
        cp(j,k) = COEF_C/COEF_B

        DO k=bottom+1,top
            bfp(j, k) = 1.0_8/(COEF_B - COEF_A*cp(j, k-1))
            cp(j, k) = COEF_C*bfp(j, k)
        ENDDO
      enddo
    ENDDO
!$OMP END DO

    call tea_block_solve(x_min, x_max, y_min, y_max,             &
                        r, z,                 &
                           cp,                     &
                           bfp,                     &
                           dp,                     &
                           Kx, Ky, rx, ry)

!$OMP DO REDUCTION(+:rro)
    DO k=y_min,y_max
        DO j=x_min,x_max
            p(j, k) = z(j, k)

            rro = rro + r(j, k)*p(j, k);
        ENDDO
    ENDDO
!$OMP END DO
  ELSE
!$OMP DO REDUCTION(+:rro)
    DO k=y_min,y_max
        DO j=x_min,x_max
            p(j, k) = r(j, k)

            rro = rro + r(j, k)*p(j, k);
        ENDDO
    ENDDO
!$OMP END DO
  ENDIF
!$OMP END PARALLEL

END SUBROUTINE tea_leaf_kernel_init_cg_fortran

SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_w(x_min,             &
                                                   x_max,             &
                                                   y_min,             &
                                                   y_max,             &
                                                   p,                 &
                                                   w,                 &
                                                   Kx,                &
                                                   Ky,                &
                                                   rx,                &
                                                   ry,                &
                                                   pw                 )

  IMPLICIT NONE

  INTEGER(KIND=4):: x_min,x_max,y_min,y_max
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: p
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: w
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Kx
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Ky

    REAL(KIND=8) ::  rx, ry

    INTEGER(KIND=4) :: j,k,n
    REAL(kind=8) :: pw

    pw = 0.0_08

!$OMP PARALLEL
!$OMP DO REDUCTION(+:pw)
    DO k=y_min,y_max
        DO j=x_min,x_max
            w(j, k) = (1.0_8                                      &
                + ry*(Ky(j, k+1) + Ky(j, k))                      &
                + rx*(Kx(j+1, k) + Kx(j, k)))*p(j, k)             &
                - ry*(Ky(j, k+1)*p(j, k+1) + Ky(j, k)*p(j, k-1))  &
                - rx*(Kx(j+1, k)*p(j+1, k) + Kx(j, k)*p(j-1, k))

            pw = pw + w(j, k)*p(j, k)
        ENDDO
    ENDDO
!$OMP END DO
!$OMP END PARALLEL

END SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_w

subroutine tea_block_solve(x_min,             &
                           x_max,             &
                           y_min,             &
                           y_max,             &
                           r,                 &
                           z,                 &
                           cp,                     &
                           bfp,                     &
                           dp,                     &
                           Kx, Ky, rx, ry)

  INTEGER(KIND=4):: j, ko, k, s, bottom, top
  INTEGER(KIND=4):: x_min,x_max,y_min,y_max
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: cp, dp, bfp, Kx, Ky, r, z
  REAL(KIND=8) :: rx, ry

!$OMP DO PRIVATE(j, bottom, top, ko, k)
    DO ko=y_min,y_max,stride

      bottom = ko
      top = ko + stride - 1

!DIR$ SIMD
      do j=x_min, x_max
        k = bottom
        dp(j, k) = r(j, k)*/COEF_B

        DO k=bottom+1,top
          dp(j, k) = (r(j, k) - COEF_A*dp(j, k-1))*bfp(j, k)
        ENDDO

        k = top
        z(j, k) = dp(j, k)

        DO k=top-1, bottom, -1
          z(j, k) = dp(j, k) - cp(j, k)*z(j, k+1)
        ENDDO
      enddo
    ENDDO
!$OMP END DO

end subroutine

SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_ur(x_min,             &
                                                    x_max,             &
                                                    y_min,             &
                                                    y_max,             &
                                                    u,                 &
                                                    p,                 &
                                                    r,                 &
                                                    Mi,                &
                                                    w,                 &
                                                    z,                 &
                                                    cp,                     &
                                                    bfp,                     &
                                                    dp,                     &
                                                    Kx, Ky, rx, ry, &
                                                    alpha,             &
                                                    rrn,               &
                                                    preconditioner_on)

  IMPLICIT NONE

  LOGICAL :: preconditioner_on
  INTEGER(KIND=4):: x_min,x_max,y_min,y_max
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: u
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: p
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: r
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: Mi
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: w
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: z

  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: cp, dp, bfp, Kx, Ky
  REAL(KIND=8) :: rx, ry

    INTEGER(KIND=4) :: j,k,n
    REAL(kind=8) :: alpha, rrn

    rrn = 0.0_08

!$OMP PARALLEL
!$OMP DO
    DO k=y_min,y_max
        DO j=x_min,x_max
            u(j, k) = u(j, k) + alpha*p(j, k)
            r(j, k) = r(j, k) - alpha*w(j, k)
        ENDDO
    ENDDO
!$OMP END DO

  IF (preconditioner_on) THEN

    call tea_block_solve(x_min, x_max, y_min, y_max,             &
                        r, z,                 &
                        cp,                     &
                        bfp,                     &
                        dp,                     &
                        Kx, Ky, rx, ry)

!$OMP DO REDUCTION(+:rrn)
    DO k=y_min,y_max
        DO j=x_min,x_max
            rrn = rrn + r(j, k)*z(j, k)
        ENDDO
    ENDDO
!$OMP END DO

  ELSE

!$OMP DO REDUCTION(+:rrn)
    DO k=y_min,y_max
        DO j=x_min,x_max
            rrn = rrn + r(j, k)*r(j, k)
        ENDDO
    ENDDO
!$OMP END DO
  ENDIF
!$OMP END PARALLEL

END SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_ur

SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_p(x_min,             &
                                                   x_max,             &
                                                   y_min,             &
                                                   y_max,             &
                                                   p,                 &
                                                   r,                 &
                                                   z,                 &
                                                   beta,              &
                                                   preconditioner_on)

  IMPLICIT NONE

  LOGICAL :: preconditioner_on
  INTEGER(KIND=4):: x_min,x_max,y_min,y_max
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: p
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: r
  REAL(KIND=8), DIMENSION(x_min-2:x_max+2,y_min-2:y_max+2) :: z

    REAL(kind=8) :: error

    INTEGER(KIND=4) :: j,k,n
    REAL(kind=8) :: beta

!$OMP PARALLEL
  IF (preconditioner_on) THEN
!$OMP DO
    DO k=y_min,y_max
        DO j=x_min,x_max
            p(j, k) = z(j, k) + beta*p(j, k)
        ENDDO
    ENDDO
!$OMP END DO NOWAIT
  ELSE
!$OMP DO
    DO k=y_min,y_max
        DO j=x_min,x_max
            p(j, k) = r(j, k) + beta*p(j, k)
        ENDDO
    ENDDO
!$OMP END DO NOWAIT
  ENDIF
!$OMP END PARALLEL

END SUBROUTINE tea_leaf_kernel_solve_cg_fortran_calc_p

END MODULE

