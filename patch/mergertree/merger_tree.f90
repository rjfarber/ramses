!-----------------------------------------------------------------
! This file contains the routines for the merger tree patch.
! See README for more information.
!
! There are two optional preprocessing definitions for this patch
! only:
! -DUNBINDINGCOM
!   use (and iteratively determine) the center of mass as the
!   center of clumps
! -DMTREEDEBUG
!   create a lot of formatted output to help debugging the merger
!   tree routines. Don't use this unless you're fighting bugs, it
!   will create a looooot of otherwise unnecessary output.
!
!
! Contains:
! subroutine make_merger_tree()
! subroutine process_progenitor_data()
! subroutine create_prog_desc_links()
! subroutine make_trees()
!   contains subroutine find_main_desc()
!            subroutine find_main_prog()
!            subroutine add_new_pmprog()
!            subroutine find_prog_in_older_snapshots()
!            subroutine dump_mergertree_debug()
! subroutine read_progenitor_data()
! subroutine write_trees()
! subroutine write_progenitor_data()
! subroutine make_galaxies()
! subroutine get_local_prog_id()
! subroutine fill_matrix()
! subroutine deallocate_mergertree()
! subroutine mark_tracer_particles()
! #ifdef MTREEDEBUG:
! subroutine mtreedebug_filename()
! subroutine mtreedebug_matrixcheck_prog()
! subroutine mtreedebug_matrixcheck_desc()
! subroutine mtreedebug_dump_unbinding_data()
! subroutine mtreedebug_dump_written_progenitor_data()
! subroutine mtreedebug_dump_written_past_merged_progenitor_data()
! subroutine mtreedebug_dump_prog_metadata()
! subroutine mtreedebug_dump_mostbound_lists()
! #endif
!-----------------------------------------------------------------



#if NDIM == 3

!================================
subroutine make_merger_tree()
!================================

  !-----------------------------------------
  ! This subroutine is the main routine for
  ! creating merger trees that calls all
  ! others.
  !-----------------------------------------
  use clfind_commons 
  use amr_commons

  implicit none

  !----------------------------
  ! Create mergertrees
  !----------------------------

  if (myid==1)write(*,'(A31,x,I5)') " Calling merger tree for output", ifout

  ! create trees only if progenitors might exist
  if (ifout > 1) then 

    ! first allocate some global arrays for current peaks
    allocate(main_prog(1:npeaks_max))
    main_prog = 0
    allocate(prog_outputnr(1:npeaks_max))
    prog_outputnr = 0

    ! Read in progenitor files
    call read_progenitor_data()

    if (nprogs > 0) then
      ! Sort out progenitor data.
      call process_progenitor_data()
      
      ! link progenitors and descendants
      call create_prog_desc_links()

      ! create trees
      call make_trees()
    endif


    if (npeaks_tot > 0) then
      ! write tree to file
      call write_trees()
    endif

  endif



  !----------------------------
  ! Prepare for next round
  !----------------------------

  if (npeaks_tot > 0) then
    ! Mark tracer particles
    call mark_tracer_particles()

    ! make mock galaxies
    if (make_mock_galaxies) then
      call make_galaxies()
    endif
  endif

  ! write progenitor output in any case
  call write_progenitor_data()

  ! Finish
  call deallocate_mergertree()


  !--------------------
  ! Say good bye.
  !--------------------

  if(verbose) write(*,*) "Finished making merger tree."

end subroutine make_merger_tree






!=====================================
subroutine process_progenitor_data()
!=====================================

  !-----------------------------------------------------
  ! This subroutine processes the progenitor data:
  !   - It finds which tracer particles are currently 
  !     on this CPU
  !   - It finds which CPU is owner of which progenitor, 
  !     and communicates that info across all CPUs.
  !   - Counts how many tracer particles of any
  !     progenitor are on this processor, create cleaned
  !     up list
  !------------------------------------------------------

  use clfind_commons
  use amr_parameters, only: i8b, dp
  use pm_commons, only: idp, npartmax
  use mpi_mod

  implicit none

#ifndef WITHOUTMPI
  integer,      allocatable, dimension(:) :: local_owners_info
#endif

  integer(i8b), allocatable, dimension(:) :: idp_copy, galaxy_tracers_copy
  integer,      allocatable, dimension(:) :: part_local_ind, sort_ind_past, dummy
  real(dp),     allocatable, dimension(:) :: dummy_real
  integer,      allocatable, dimension(:) :: tracers_local_pid_long, tracer_local_ids_long
  integer :: itrace, ipart, igalaxy, ipastprog, i, iprog

  if (verbose) write(*,*) " processing progenitor data."


  !-------------------
  ! Allocate stuff
  !-------------------

  ! Create copies of arrays you mustn't modify
  allocate(idp_copy(1:npartmax))
  idp_copy = idp

  allocate(galaxy_tracers_copy(1:nprogs))
  galaxy_tracers_copy = galaxy_tracers

  ! allocate others
  if (nprogs > npastprogs) then
    allocate(dummy(1:nprogs))
  else
    allocate(dummy(1:npastprogs))
  endif
  dummy = 1
  allocate(dummy_real(1:npastprogs))

  allocate(part_local_ind(1:npartmax))
  part_local_ind = [(i, i = 1, npartmax)]

  allocate(sort_ind_past(1:npastprogs))
  sort_ind_past = [(i, i=1, npastprogs)]

  allocate(tracers_local_pid_long(1:nprogs*nmost_bound)) ! local particle   id for tracers (room enough for all tracers)
  allocate(tracer_local_ids_long(1:nprogs*nmost_bound))  ! local progenitor id for tracers (room enough for all tracers)

  if (make_mock_galaxies) then
    allocate(orphans_local_pid(1:npastprogs+nprogs))
    orphans_local_pid = 0
    allocate(prog_galaxy_local_id(1:nprogs))
    prog_galaxy_local_id = 0
  endif



  !---------------------------------
  ! Sort arrays for quick matching
  !---------------------------------

  ! Sort arrays for matching
  call quick_sort_int_int(idp_copy, part_local_ind, npartmax)
  call quick_sort_int_int(tracers_all, tracer_loc_progids_all, nprogs*nmost_bound)
  call quick_sort_int_int(galaxy_tracers_copy, dummy, nprogs)

  ! sort past progenitors in-place by galaxy particle ID;
  ! will be needed later for multi-snapshot progenitor search
  call quick_sort_int_int(pmprogs_galaxy, sort_ind_past, npastprogs)

  dummy(1:npastprogs) = pmprogs(1:npastprogs)
  do i = 1, npastprogs
    pmprogs(i) = dummy(sort_ind_past(i))
  enddo

  dummy(1:npastprogs) = pmprogs_t(1:npastprogs)
  do i = 1, npastprogs
    pmprogs_t(i) = dummy(sort_ind_past(i))
  enddo

  dummy_real(1:npastprogs) = pmprogs_mass(1:npastprogs)
  do i = 1, npastprogs
    pmprogs_mass(i) = dummy_real(sort_ind_past(i))
  enddo

  dummy_real(1:npastprogs) = pmprogs_mpeak(1:npastprogs)
  do i = 1, npastprogs
    pmprogs_mass(i) = dummy_real(sort_ind_past(i))
  enddo

  deallocate(dummy, dummy_real, sort_ind_past)




  !------------------------
  ! find starting indices
  !------------------------

  itrace = 0; ipart = 0; igalaxy = 0; iprog = 0;

  do i = 1, npartmax
    if (idp_copy(i) > 0) then
      ipart = i
      exit
    endif
  enddo

  do i = 1, nprogs*nmost_bound
    if (tracers_all(i) > 0) then
      itrace = i
      exit
    endif
  enddo

  igalaxy = 1
  ipastprog = 1

  ntracers = 0 




  !--------------------------------------------------------------
  ! Identify which progenitor tracer particles are on this CPU.
  ! loop over all local particles and all progenitor particles.
  ! at this point, both arrays are sorted.
  ! Raise the array index of array which has lower particle ID 
  ! to find matches.
  !--------------------------------------------------------------

  do while (ipart <= npartmax)

    !-------------------------------------------------------------------------------------
    ! Check for tracers and past progenitor galaxies while itrace <= nprogs*nmost_bound 
    !-------------------------------------------------------------------------------------

    do while (itrace <= nprogs * nmost_bound .and. ipart <= npartmax) 
      ! if particles aren't a match, raise the index where lower ID is
      if (tracers_all(itrace) < idp_copy(ipart)) then
        itrace = itrace + 1

      else if (tracers_all(itrace) > idp_copy(ipart)) then
        ! before raising local particle index, check whether you own a past progenitor
        ! no need to check whether npastprogs > 0: arrays are allocated
        ! (1:npastprogs+nprogs) to have extra space in case new progs
        ! need to be added to the list
        do while (ipastprog <= npastprogs)
          if (pmprogs_galaxy(ipastprog) < idp_copy(ipart)) then
              ipastprog = ipastprog + 1
          else if (pmprogs_galaxy(ipastprog) == idp_copy(ipart)) then 
            ! you found a match!
            pmprogs_owner(ipastprog) = myid
            if (make_mock_galaxies) orphans_local_pid(ipastprog) = part_local_ind(ipart)
            ipastprog = ipastprog + 1
          else  
            exit
          endif
        enddo
        ipart = ipart + 1


      else
        !----------------
        ! found a match!
        !----------------
        iprog = tracer_loc_progids_all(itrace)
        ! count the tracer for corresponding prog
        ! add to list of this CPU
        ntracers = ntracers + 1                                   ! count one more tracer on this cpu
        tracers_local_pid_long(ntracers) = part_local_ind(ipart)  ! save local particle ID
        tracer_local_ids_long(ntracers) = iprog                   ! save local prog ID it belongs to

        ! check if found tracer is also a galaxy:
        do while (igalaxy <= nprogs)
          if (galaxy_tracers_copy(igalaxy) < tracers_all(itrace)) then
            igalaxy = igalaxy + 1
          else if (galaxy_tracers_copy(igalaxy) == tracers_all(itrace)) then
            prog_owner(iprog) = myid
            if (make_mock_galaxies) prog_galaxy_local_id(iprog) = part_local_ind(ipart)   ! store local ID of galaxy particle
            igalaxy = igalaxy + 1
            exit
          else
            exit
          endif
        enddo

        ipart = ipart + 1
        itrace = itrace + 1
      endif

    enddo
      

    ! reset ipart in case it reached the limit in the previous loop
    if (ipart>npartmax) ipart = npartmax

    !---------------------------------------------------------------------------
    ! If there are no more tracers to check for, check only for past galaxies
    !---------------------------------------------------------------------------
    do while (ipastprog <= npastprogs)
      if (pmprogs_galaxy(ipastprog) < idp_copy(ipart)) then
          ipastprog = ipastprog + 1
      else if (pmprogs_galaxy(ipastprog) == idp_copy(ipart)) then 
        ! you found a match!
        pmprogs_owner(ipastprog) = myid
        if (make_mock_galaxies) orphans_local_pid(ipastprog) = part_local_ind(ipart)
        ipastprog = ipastprog + 1
      else  
        exit
      endif
    enddo

    if (ipastprog > npastprogs) exit
    ipart = ipart + 1

  enddo


  deallocate(idp_copy, galaxy_tracers_copy, part_local_ind)




  !---------------------------------------------------
  ! Clean up local tracers information for this CPU
  !---------------------------------------------------

  allocate(tracers_loc_pid(1:ntracers))
  allocate(tracer_loc_progids(1:ntracers))

  tracers_loc_pid(1:ntracers) = tracers_local_pid_long(1:ntracers)
  tracer_loc_progids(1:ntracers) = tracer_local_ids_long(1:ntracers)

  ! Deallocate auxilliary arrays
  deallocate(tracer_local_ids_long, tracers_local_pid_long)

  ! Deallocate global arrays that aren't used anymore
  deallocate(tracers_all) 
  deallocate(tracer_loc_progids_all)
  



#ifndef WITHOUTMPI
  !--------------------------------
  ! communicate progenitor owners
  !--------------------------------

  ! first the actual progenitors
  allocate(local_owners_info(1:nprogs))     ! progenitor owners array, local to each cpu
  local_owners_info = prog_owner
  call MPI_ALLREDUCE(local_owners_info, prog_owner, nprogs, MPI_INTEGER, MPI_MAX, MPI_COMM_WORLD, i)
  deallocate(local_owners_info)

  ! then the past progenitors
  allocate(local_owners_info(1:npastprogs)) ! progenitor owners array, local to each cpu
  local_owners_info = pmprogs_owner(1:npastprogs)
  call MPI_ALLREDUCE(local_owners_info, pmprogs_owner, npastprogs, MPI_INTEGER, MPI_MAX, MPI_COMM_WORLD, i)
  deallocate(local_owners_info)
#endif


  return

end subroutine process_progenitor_data







!=====================================
subroutine create_prog_desc_links()
!=====================================

  !--------------------------------------------------------------------
  ! Establishes connections between progenitors and descendants via
  ! tracer particles, i.e. in which descendant they ended up.
  ! Initialises p2d_links matrix, then all data are combined at the
  ! progenitor owner's CPU.
  !--------------------------------------------------------------------

  use clfind_commons
  use mpi_mod
  implicit none

  integer :: iprog, ipart, ind, idesc, i

#ifndef WITHOUTMPI
  integer, dimension(:), allocatable :: sendcount, receivecount
  integer, dimension(:), allocatable :: sendcount2, receivecount2
  integer, dimension(:), allocatable :: sendbuf, recvbuf
  integer, dimension(:), allocatable :: sendbuf2, recvbuf2
  integer, dimension(:), allocatable :: send_displ, rec_displ
  integer :: icpu, ind2, recndesc
#endif

  if (verbose) write(*,*) "linking progenitors and descendants."


  !------------------------------------------------------------------
  ! Initialise sparse matrix for progenitors->descendant (p2d) links
  !------------------------------------------------------------------

  allocate(p2d_links%first(1:nprogs))
  p2d_links%first = 0
  allocate(p2d_links%cnt(1:nprogs))
  p2d_links%cnt = 0
  allocate(p2d_links%clmp_id(1:10*npeaks_max))
  p2d_links%clmp_id = 0
  allocate(p2d_links%ntrace(1:10*npeaks_max))
  p2d_links%ntrace = 0
  allocate(p2d_links%next(1:10*npeaks_max))
  p2d_links%next = 0




  !----------------------------
  ! Fill up matrix with values 
  !----------------------------

  i = 0
  do ipart = 1, ntracers
    ! If tracer is currently in a descendant clump, add it to list
    if (clmpidp(tracers_loc_pid(ipart)) /= 0) then
      call fill_matrix(p2d_links, tracer_loc_progids(ipart), clmpidp(tracers_loc_pid(ipart)), 1, 'add')
    else
      i = i + 1 ! count how many zeros 
    endif
  enddo

#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(MPI_IN_PLACE, i, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD, ipart)
#endif

  if (myid == 1) write(*, '(A6,x,I9,x,A58)') " Found", i, "progenitor tracer particles that are not in clumps anymore."
  
  deallocate(tracers_loc_pid, tracer_loc_progids)




#ifndef WITHOUTMPI

  !=====================================================
  ! PART 1: 
  ! Send local progenitor data to progenitor owners
  !=====================================================

  !------------------------------------------------------------------------
  ! Find out how much stuff you need to send where.
  ! You'll send an array of the form: ("#" = "number of")
  ! prog1_local_id, # descendants, descendant 1 ID, 
  !   #tracers in desc1, descendant 2 ID, #tracers in desc 2, ...,
  ! prog2_local_id, #descendants, descendant 1 ID, #tracers in desc1, ...
  !
  ! prog_local_id should be the same on every CPU
  !-------------------------------------------------------------------------

  allocate(sendcount(1:ncpu))
  sendcount = 0
  allocate(receivecount(1:ncpu))
  receivecount = 0


  do iprog = 1, nprogs
    ! if progenitor has tracers on this cpu
    if ( p2d_links%cnt(iprog)> 0 .and. prog_owner(iprog) /= myid) then
      sendcount(prog_owner(iprog)) = sendcount(prog_owner(iprog)) + 2 + 2 * p2d_links%cnt(iprog)
    endif
  enddo



  !---------------------------------
  ! Share infos across processors
  !---------------------------------

  call MPI_ALLTOALL(sendcount, 1, MPI_INT, receivecount, 1, MPI_INT, MPI_COMM_WORLD, i)


 
  !-------------------------
  ! Send actual data
  !-------------------------

  allocate(sendbuf(1:sum(sendcount)))
  allocate(recvbuf(1:sum(receivecount)))

  ! Fill up sendbuffer
  ind = 1
  do icpu = 1, ncpu
    if (icpu /= myid) then
      do iprog = 1, nprogs

        if (p2d_links%cnt(iprog) > 0 .and. prog_owner(iprog) == icpu) then

          sendbuf(ind) = iprog
          sendbuf(ind+1) = p2d_links%cnt(iprog)
          ind = ind + 2

          idesc = p2d_links%first(iprog)

          ! for each descendant:
          do i = 1, p2d_links%cnt(iprog)
            sendbuf(ind) = p2d_links%clmp_id(idesc)
            sendbuf(ind+1) = p2d_links%ntrace(idesc)
            idesc = p2d_links%next(idesc)
            ind = ind + 2
          enddo
        endif
      enddo
    endif
  enddo


  allocate(send_displ(1:ncpu), rec_displ(1:ncpu))
  send_displ = 0; rec_displ = 0;

  do i = 2, ncpu
    send_displ(i) = send_displ(i-1) + sendcount(i-1)
    rec_displ(i) = rec_displ(i-1) + receivecount(i-1)
  enddo

  call MPI_ALLTOALLV(sendbuf, sendcount, send_displ, MPI_INT, &
    recvbuf, receivecount, rec_displ, MPI_INT, MPI_COMM_WORLD, i)



  !----------------------------------------------
  ! Sum up newly arrived values if you are owner
  !----------------------------------------------

  ind = 1
  do while (ind <= sum(receivecount))
    iprog = recvbuf(ind)
    recndesc = recvbuf(ind + 1)
    ind = ind + 2
    do idesc = 1, recndesc
      call fill_matrix(p2d_links, iprog, recvbuf(ind), recvbuf(ind+1), 'add')
      ind = ind + 2 ! skip 2: first is descendant ID, second is # particles
    enddo
  enddo




  !=========================================================
  ! PART 2: 
  ! Broadcast progenitor data from owners to not-owner CPUs
  !=========================================================

  !-----------------------------------------------
  ! Find out how much to send where
  ! Must be done second: Depends on how much data
  ! you received. Same data structure to send.
  !-----------------------------------------------

  allocate(sendcount2(1:ncpu))
  sendcount2 = 0
  allocate(receivecount2(1:ncpu))
  receivecount2 = 0

  ind = 1
  icpu = 1
  do while (ind <= sum(receivecount))
    if (icpu < ncpu) then
      do while(ind > rec_displ(icpu+1))
        icpu = icpu + 1
        if (icpu == ncpu) exit
      enddo
    endif
    iprog = recvbuf(ind)
    recndesc = recvbuf(ind + 1)
    sendcount2(icpu) = sendcount2(icpu) + 2 + 2*p2d_links%cnt(iprog)
    ind = ind + 2 + 2 * recndesc
  enddo



  !---------------------------------
  ! Share infos across processors
  !---------------------------------

  call MPI_ALLTOALL(sendcount2, 1, MPI_INT, receivecount2, 1, MPI_INT, MPI_COMM_WORLD, i)



  !-------------------------
  ! Send actual data
  !-------------------------

  allocate(sendbuf2(1:sum(sendcount2)))
  allocate(recvbuf2(1:sum(receivecount2)))

  ind = 1  ! index for previously received array; 
           ! needed to identify which progenitor to send where
  ind2 = 1 ! index for new array to send stuff
  do while (ind <= sum(receivecount))
    iprog = recvbuf(ind)
    recndesc = recvbuf(ind+1) !needed to skip correctly to next iprog
    ind = ind + 2 + 2 * recndesc

    sendbuf2(ind2) = iprog
    sendbuf2(ind2 + 1) = p2d_links%cnt(iprog)
    ind2 = ind2 + 2

    idesc = p2d_links%first(iprog)
    ! write each descendant
    do i = 1, p2d_links%cnt(iprog)
      sendbuf2(ind2) = p2d_links%clmp_id(idesc)
      sendbuf2(ind2+1) = p2d_links%ntrace(idesc)
      idesc = p2d_links%next(idesc)
      ind2 = ind2 + 2
    enddo
  enddo


  send_displ = 0; rec_displ = 0;

  do i = 2, ncpu
    send_displ(i) = send_displ(i-1) + sendcount2(i-1)
    rec_displ(i) = rec_displ(i-1) + receivecount2(i-1)
  enddo

  call MPI_ALLTOALLV(sendbuf2, sendcount2, send_displ, MPI_INT, &
    recvbuf2, receivecount2, rec_displ, MPI_INT, MPI_COMM_WORLD, i)




  !-----------------------------
  ! Sum up newly arrived values
  !-----------------------------

  ind = 1
  do while (ind <= sum(receivecount2))
    iprog = recvbuf2(ind)
    recndesc = recvbuf2(ind + 1)
    ind = ind + 2
    do idesc = 1, recndesc
      call fill_matrix(p2d_links, iprog, recvbuf2(ind), recvbuf2(ind+1), 'set')
      ind = ind + 2 ! skip 2: first is descendant ID, second is # particles
    enddo
  enddo




  !-------------------
  ! Cleanup
  !-------------------

  deallocate(sendcount,  receivecount)
  deallocate(sendcount2, receivecount2)
  deallocate(sendbuf,    recvbuf)
  deallocate(sendbuf2,   recvbuf2)
  deallocate(send_displ, rec_displ)

  ! end infdef WITHOUTMPI: No sending at all necessary.
#endif 




  !-----------------------------------------------
  ! Create descendants-to-progs ( = d2p) matrix
  !-----------------------------------------------

  allocate(d2p_links%first(1:npeaks_max))
  d2p_links%first = 0
  allocate(d2p_links%cnt(1:npeaks_max))
  d2p_links%cnt = 0
  allocate(d2p_links%clmp_id(1:10*npeaks_max))
  d2p_links%clmp_id = 0
  allocate(d2p_links%ntrace(1:10*npeaks_max))
  d2p_links%ntrace = 0
  allocate(d2p_links%next(1:10*npeaks_max))
  d2p_links%next = 0


  do iprog = 1, nprogs
    ind = p2d_links%first(iprog)
    do i = 1, p2d_links%cnt(iprog)
      call get_local_peak_id(p2d_links%clmp_id(ind), idesc)
      call fill_matrix(d2p_links, idesc, iprog, p2d_links%ntrace(ind), 'add')
      ind = p2d_links%next(ind)
    enddo
  enddo


  return

end subroutine create_prog_desc_links








!===========================
subroutine make_trees()
!===========================

  !---------------------------------------------------------------------------
  ! This subroutine establishes the tree.
  ! First we obtain initial guesses for main progenitors of descendants and
  ! main descendants of progenitors.
  ! Secondly, a loop is performed until each descendant has found a main
  ! progenitor or has no more suitable candidates. In each step of the loop,
  ! all descendant candidates of all progenitors which still haven't found a
  ! matching direct descendant are checked for a match.
  ! When the loop is over, all descendants that haven't got a main progenitor
  ! are checked for the possibility of containing a past merged progenitor.
  !---------------------------------------------------------------------------

  use clfind_commons
  use mpi_mod

  implicit none

  real(dp), dimension(:), allocatable ::  merit_desc
  real(dp), dimension(:), allocatable ::  merit_desc_copy
  logical,  dimension(:), allocatable ::  to_iter_prog

  integer :: iprog, ipeak, i, loopcounter
  integer :: peakshift
  real(dp):: r_null
  logical :: found, reiter

  if (verbose) write(*,*) "making trees."


  !============================================
  ! PART 1: Preparation and initial guesses
  !============================================

  allocate(main_desc(1:nprogs))
  main_desc = 0
  allocate(merit_desc(1:npeaks_max))
  merit_desc = 0

  allocate(merit_desc_copy(1:npeaks_max))
  allocate(to_iter_prog(1:nprogs))


  !-----------------------------------
  ! Make sure you have necessary
  ! clump data available on this cpu
  !-----------------------------------
  call build_peak_communicator()
  call boundary_peak_dp(clmp_mass_exclusive)
  if (.not. use_exclusive_mass) call boundary_peak_dp(clmp_mass_pb(:))


  !-------------------------------------------------------------
  ! Find initial guess for main descendant for each progenitor
  !-------------------------------------------------------------

  do iprog = 1, nprogs
    if (prog_owner(iprog)==myid .and. p2d_links%cnt(iprog)>0) then
      call find_main_desc(iprog, found)
    endif
  enddo

  ! initialise what needs to be checked before communication:
  ! Otherwise, you'll introduce way too many virtual peaks for no reason.
  ! (only processors that have progenitor particles on them might have 
  ! reason to introduce virtual peaks of descendant candidates, all others
  ! don't)
  to_iter_prog = (main_desc > 0) .and. (prog_owner == myid)

#ifndef WITHOUTMPI
    !-------------------------
    ! Communicate results. 
    !-------------------------
    ! All CPUs that have tracer particles of any progenitor
    ! have full data of that progenitor; But it might be that there is a descendant,
    ! split among multiple CPU's, where some CPU's have missing progenitor data  
    ! because they don't have any progenitor's particles on their domain. Such
    ! descendants will need to know main_desc values which will otherwise be unknown.
    ! First reset values: If you had a main_desc with a higher ID previously, you'll
    ! get junk results. Unlike with descendants, keeping only main_desc of the owner 
    ! CPU is safe, as all CPUs that have tracer particles of a progenitor have full 
    ! data of that progenitor.
    call MPI_ALLREDUCE(MPI_IN_PLACE, main_desc, nprogs, MPI_INT, MPI_MAX, MPI_COMM_WORLD, i)
#endif


#ifdef MTREEDEBUG
  call mtreedebug_matrixcheck_prog(.true.)
#endif

  
  !-------------------------------------------------------------
  ! Find initial guess for main progenitor for each descendant
  !-------------------------------------------------------------

  do ipeak = 1, hfree-1
    if (d2p_links%cnt(ipeak) > 0) then
      call find_main_prog(ipeak, merit_desc, found)
      ! mark the progenitor candidate you used
      if (found) then
        call fill_matrix(d2p_links, ipeak, main_prog(ipeak), 0, 'inv')
      endif
    endif
  enddo


#ifndef WITHOUTMPI
  ! Check whether there are better progenitor candidates 
  ! on other processors
  merit_desc_copy = merit_desc
  call virtual_peak_dp(merit_desc(:), 'max')
  call boundary_peak_dp(merit_desc(:))

  do ipeak = 1, hfree-1
    if ( merit_desc_copy(ipeak) < merit_desc(ipeak)) then
      ! unmark the peak you found so you can re-check it if necessary,
      ! then reset main prog for comm
      if (main_prog(ipeak) > 0) then
        call fill_matrix(d2p_links, ipeak, main_prog(ipeak), 0, 'inv')
        main_prog(ipeak) = 0
      endif
    endif
  enddo
  
  call virtual_peak_int(main_prog(:), 'max')
  call boundary_peak_int(main_prog(:))
#endif

  ! initialise what needs to be checked.
  to_iter = (main_prog > 0)



  !-------------------------
  ! Introduce peak shift:
  !-------------------------
  ! Shift the peak of special cases like past merged progenitors as
  ! main progenitors and mergers by a high number so you still can
  ! use MAX reduction and know that they're special cases
  peakshift = 10*(ipeak_start(ncpu)+npeaks_max)

 
#ifdef MTREEDEBUG
  call mtreedebug_matrixcheck_desc(.true.)
#endif


  !==================================
  ! PART 2: TREEMAKING LOOP
  !==================================

  !------------------------------------------------------------------------------
  ! To establish a connection over snapshots, the main descendant of each
  ! progenitor must have said progenitor as the main progenitor.
  ! In each iteration, progenitors which haven't found such a match go through
  ! all possible descendant candidates, trying to find a match. If no such 
  ! match is found, it is assumed that the progenitor merged into the initial
  ! best guess.
  ! Then descendants are checked for having the correct main progenitor
  ! identified. If this isn't the case, the guess is moved to the next best
  ! candidate (per iteration, it moves only to 1 next candidate), after which i
  ! the entire loop is restarted.
  !------------------------------------------------------------------------------

  reiter = .true.
  loopcounter = 0

  do while (reiter)

    reiter = .false.

    ! check progenitors:
    call search_main_desc_loop()

    ! Check descendants: 
    call search_main_prog_loop(reiter)

#ifndef WITHOUTMPI
    ! check globally whether you need to reiterate treebuilding loop
    call MPI_ALLREDUCE(MPI_IN_PLACE, reiter, 1, MPI_LOGICAL, MPI_LOR, MPI_COMM_WORLD, i)
#endif

    loopcounter = loopcounter + 1
    if (loopcounter == 1000) then
      reiter = .false.
      if (myid==1) write(*,*) "Mergertree loop reached 1000 iterations. Dumping debug data and proceeding."
      call dump_mergertree_debug()
    endif

  enddo
  !----------------------------------------------------------------------------------
  ! End of treemaking loop
  ! now repeat part for progenitors one last time in case the match was found in
  ! the last loop
  !--------------------------------------------------------------------------------
 
  call search_main_desc_loop()





  !===================================================
  ! PART 3: Look for progenitors in older snapshots
  !===================================================

  !---------------------------------------------------------------------------
  ! After tree is made, add merged progenitors to past merged progenitors
  !---------------------------------------------------------------------------
  do iprog = 1, nprogs
    if (main_desc(iprog)<0 .and. prog_owner(iprog) == myid) then
      call add_new_pmprog(iprog)
    endif
  enddo
  

  ! first check if you have work to do and set up prog_outputnr
  ! abuse "reiter" to find out whether there is work to be done.
  ! (it wont actually be done iteratively.)
  reiter = .false.
  to_iter = .false.
  do ipeak = 1, npeaks_max
    if (clmp_mass_exclusive(ipeak) > 0) then
      if (main_prog(ipeak)==0) then
        ! if you still haven't got a progenitor, mark for checking
        to_iter(ipeak) = .true.
        reiter = .true.
      else
        ! otherwise, mark that this progenitor was an active clump in the last snapshot
        prog_outputnr(ipeak) = ifout-1
      endif
    endif
  enddo


#ifndef WITHOUTMPI
  ! check globally whether you have work to do; Otherwise, MPI will deadlock.
  call MPI_ALLREDUCE(MPI_IN_PLACE, reiter, 1, MPI_LOGICAL, MPI_LOR, MPI_COMM_WORLD, i)
#endif


  if (reiter) then
    !---------------------------------------------------------------------------------
    ! update all necessary unbinding arrays in case you introduced new virtual peaks
    !---------------------------------------------------------------------------------
    do i = 1, nmassbins
      call boundary_peak_dp(cmp(1,i))
    enddo

    do i = 1, 3
      call boundary_peak_dp(peak_pos(1,i))
      call boundary_peak_dp(clmp_vel_pb(1,i))
    enddo

    call boundary_peak_dp(cmp_distances(1,nmassbins))

    ! recompute cumulative mass profile bin distances for virtual peaks
    do ipeak=npeaks+1, hfree-1

      ! set up distances only if you haven't yet
      if (cmp_distances(ipeak, nmassbins-1)==0d0) then
        if (logbins) then
          do i=1, nmassbins-1
            ! rmin is declared in clfind_commons
            cmp_distances(ipeak,i)=rmin*(cmp_distances(ipeak,nmassbins)/rmin)**(real(i)/real(nmassbins))
          enddo
        else ! linear binnings
          r_null=cmp_distances(ipeak,nmassbins)/real(nmassbins)
          do i=0, nmassbins-1
            cmp_distances(ipeak,i)=r_null*i
          enddo
        endif
      endif
    enddo


    !------------------------------------------------------------------
    ! If you still haven't found a progenitor for a descendant, 
    ! try looking in previous, non-adjacent snapshots.
    !------------------------------------------------------------------

    ! reset merit and to_iter arrays
    merit_desc = 0

    do ipeak = 1, hfree-1
      if ( to_iter(ipeak) ) then ! if there is something to check for
          call find_prog_in_older_snapshots(ipeak, peakshift, merit_desc)
      endif
    enddo



    !-------------------------------------------------------
    ! Check that you found best candidate across processors
    !-------------------------------------------------------
    merit_desc_copy = merit_desc
    ! Here the best candidate has the lowest merit value! 
    call virtual_peak_dp(merit_desc(:), 'min')
    call boundary_peak_dp(merit_desc(:))

    do ipeak = 1, hfree-1
      if ( to_iter(ipeak)) then
        if (merit_desc_copy(ipeak) > merit_desc(ipeak)) then
          ! if you don't have the best candidate, reset
          main_prog(ipeak) = 0
          prog_outputnr(ipeak) = 0
        else
          if (prog_outputnr(ipeak)>0) then
            ! overwrite pmprog as taken, get actual snapshot nr of pmprog. 
            ! prog_outputnr(ipeak) contains the merit_min_id for this ipeak for this case!
            pmprogs_owner(prog_outputnr(ipeak)) = 0 ! pmprogs will be written to file by owner. If no owner, it won't be written!
            prog_outputnr(ipeak) = pmprogs_t(prog_outputnr(ipeak))
          endif
        endif
      endif
    enddo


    ! Communicate results
    call virtual_peak_int(main_prog, 'max')
    call virtual_peak_int(prog_outputnr, 'max')
    ! After this routine, only writing the trees to file is done.
    ! virtual peaks need no knowledge of the results.
    ! call boundary_peak_int(main_prog)
    ! call boundary_peak_int(prog_outputnr)

    ! Mark progenitors from earlier snapshots as such
    do ipeak = 1, npeaks
      if (main_prog(ipeak) > peakshift ) then
        main_prog(ipeak) = - (main_prog(ipeak)-peakshift)
      endif
    enddo

  endif ! to look for progs in older snapshots


  !-------------------------
  ! Cleanup before finish
  !-------------------------

  deallocate(merit_desc_copy)
  deallocate(merit_desc)
  deallocate(to_iter_prog)


#ifdef MTREEDEBUG
  call mtreedebug_matrixcheck_prog(.false.)
  call mtreedebug_matrixcheck_desc(.false.)
#endif
  return




  contains 

    !==============================================
    subroutine find_main_desc(iprog, found_one)
    !==============================================

      !-------------------------------------------------
      ! Find the main descendant of progenitor iprog
      !-------------------------------------------------

      use clfind_commons
      implicit none
      integer, intent(in)   :: iprog      ! local progenitor id
      logical, intent(out)  :: found_one  ! whether you found a new candidate

      real(dp) :: merit_max, merit_calc, a, clumpmass 
      integer  :: merit_max_id
      integer  :: ind, i, idesc, idl

      merit_max = 0
      merit_max_id = 0

      ind = p2d_links%first(iprog)

      ! loop over all descendants
      do i = 1, p2d_links%cnt(iprog)
        
        ! if there are particles left 
        ! (might have been removed during matching)
        if (p2d_links%ntrace(ind) > 0) then
          idesc = p2d_links%clmp_id(ind)
          call get_local_peak_id(idesc, idl)

          if (use_exclusive_mass) then
            clumpmass = clmp_mass_exclusive(idl)
          else
            clumpmass = clmp_mass_pb(idl)
          endif

          ! calculate merits
          if (clumpmass > prog_mass(iprog)) then
            a = abs(1 - clumpmass/prog_mass(iprog))
          else
            a = abs(1 - prog_mass(iprog)/clumpmass)
          endif

          if (a<1d-100) a = 1d-100 ! don't devide by zero
          merit_calc =  real(p2d_links%ntrace(ind)) / a**2

          if (merit_calc > merit_max) then
            merit_max = merit_calc
            merit_max_id = idesc
          endif
        endif

        ind = p2d_links%next(ind)

      enddo

      if (merit_max_id > 0) then
        found_one = .true.
        main_desc(iprog) = merit_max_id
      else
        found_one = .false.
        main_desc(iprog) = -7
        ! essentially this means there is no descendant for this progenitor.
        ! so.. disappearing clumps? Might be possible if you had very small
        ! clumps that dissolved over time
      endif

    end subroutine find_main_desc





    !===========================================================
    subroutine find_main_prog(ipeak, merit_desc, found_one)
    !===========================================================

      !-------------------------------------------------
      ! Find the main progenitor of descendant ipeak.
      !-------------------------------------------------

      use clfind_commons
      
      implicit none
      integer, intent(in)                             :: ipeak      ! descendant local id
      real(dp), dimension(1:npeaks_max), intent(inout):: merit_desc ! array where to store merit for this prog candidate
      logical, intent(out)                            :: found_one  ! whether you found a new candidate

      real(dp):: merit_max, merit_calc, a, clumpmass
      integer :: merit_max_id
      integer :: ind, i, iprog

      merit_max = 0
      merit_max_id = 0

      ind = d2p_links%first(ipeak)

      do i = 1, d2p_links%cnt(ipeak)
        iprog = d2p_links%clmp_id(ind)

        if (d2p_links%ntrace(ind) > 0) then
          if (use_exclusive_mass) then
            clumpmass = clmp_mass_exclusive(ipeak)
          else
            clumpmass = clmp_mass_pb(ipeak)
          endif

          ! calculate merit
          if (clumpmass > prog_mass(iprog)) then
            a = abs(1 - clumpmass/prog_mass(iprog))
          else
            a = abs(1 - prog_mass(iprog)/clumpmass)
          endif
          if (a<1d-100) a = 1d-100 ! don't devide by zero
          merit_calc = real(d2p_links%ntrace(ind))/a**2

          if (merit_calc > merit_max) then
            merit_max = merit_calc
            merit_max_id = iprog
          endif
        endif

        ind = d2p_links%next(ind)

      enddo

      if (merit_max_id > 0) then
        ! save results
        main_prog(ipeak) = merit_max_id
        merit_desc(ipeak) = merit_max
        found_one = .true.
      else
        main_prog(ipeak) = 0
        found_one = .false.
      endif

    end subroutine find_main_prog





    !=====================================
    subroutine add_new_pmprog(iprog)
    !=====================================

      !-----------------------------------------------------------
      ! Add new progenitor to the list of past merged progenitors
      !-----------------------------------------------------------

      use clfind_commons
      implicit none
      integer, intent(in) :: iprog ! local prog index to add

      pmprogs(pmprog_free) = prog_id(iprog)
      pmprogs_galaxy(pmprog_free) = galaxy_tracers(iprog)
      pmprogs_t(pmprog_free) = ifout-1 ! prog was active clump for the last time at this timestep 
      pmprogs_owner(pmprog_free) = myid
      pmprogs_mass(pmprog_free) = prog_mass(iprog)
      if (make_mock_galaxies) then
        orphans_local_pid(pmprog_free) = prog_galaxy_local_id(iprog)
        pmprogs_mpeak(pmprog_free) = prog_mpeak(iprog)
      endif
      pmprog_free = pmprog_free + 1

      return

    end subroutine add_new_pmprog





    !=====================================================================
    subroutine find_prog_in_older_snapshots(ipeak, peakshift, merit_desc)
    !=====================================================================

      !--------------------------------------------------------
      ! If no progenitor from adjacent snapshot has been found,
      ! this subroutine looks for a possible progenitor in an
      ! earlier snapshot.
      ! Here, the merit is to be minimized: It is the binding
      ! energy of possible candidates
      !--------------------------------------------------------

      use clfind_commons
      use pm_commons, only: idp

      implicit none

      integer, intent(in)                              :: ipeak
      integer, intent(in)                              :: peakshift
      real(dp), intent(inout), dimension(1:npeaks_max) :: merit_desc

      integer, dimension(:), allocatable :: particlelist   ! list of particle IDs of this clump
      integer, dimension(:), allocatable :: canddts        ! list of progenitor candidates
      real(dp),dimension(:), allocatable :: merit          ! merit of progenitor candidates
      integer, dimension(:), allocatable :: part_local_ind ! local particle index for clumpparticles
      integer                            :: ncand          ! number of candidates

      integer  :: ipart, thispart, iclump, ipastprog, lpcid, merit_min_id
      real(dp) :: merit_min


      if (nclmppart(ipeak) > 0) then
        !-------------
        ! Set up
        !-------------

        ncand = 0

        allocate(canddts(1:npastprogs_max))
        allocate(merit(1:npastprogs_max))

        allocate(particlelist(1:nclmppart(ipeak)))
        particlelist = 0
        allocate(part_local_ind(1:nclmppart(ipeak)))


        ! Get particle ID list for this clump
        thispart = clmppart_first(ipeak)
        do ipart = 1, nclmppart(ipeak)
          if (clmpidp(thispart) > 0) then
            call get_local_peak_id(clmpidp(thispart), lpcid)
            if (ipeak == lpcid) then
              particlelist(ipart) = idp(thispart)
              part_local_ind(ipart) = thispart
            endif
          endif
          thispart = clmppart_next(thispart)
        enddo
        
        ! Sort the list for matching with galaxy particles
        call quick_sort_int_int(particlelist, part_local_ind, nclmppart(ipeak))

        ! Find starting values
        iclump = 1
        do ipart = 1, nclmppart(ipeak)
          if (particlelist(ipart) > 0) then
            iclump = ipart
            exit
          endif
        enddo

        ipastprog = 1



        !-------------------------------------------------------------------
        ! Find candidates by checking if any particle in clump is a galaxy
        ! of a past merged progenitor
        !-------------------------------------------------------------------

        call compute_phi(ipeak)

        do while (iclump <= nclmppart(ipeak) .and. ipastprog <= npastprogs)
          
          if (particlelist(iclump) < pmprogs_galaxy(ipastprog)) then
            iclump = iclump + 1
          else if (particlelist(iclump) > pmprogs_galaxy(ipastprog)) then
            ipastprog = ipastprog + 1
          else
            ! Found a match!
            ncand = ncand + 1
            canddts(ncand) = ipastprog ! store local ID
            call eparttot(ipeak, part_local_ind(iclump), merit(ncand))
            ipastprog = ipastprog + 1
            iclump = iclump + 1
          endif
        enddo
        

        ! Find the one with actual minimal merit
        merit_min_id = 0
        merit_min = HUGE(0d0)
        do ipastprog = 1, ncand
          if (merit(ipastprog) < merit_min) then
            merit_min = merit(ipastprog)
            merit_min_id = canddts(ipastprog)
          endif
        enddo

        ! If there is one, store values
        if (merit_min_id > 0) then
          main_prog(ipeak) = pmprogs(merit_min_id) + peakshift
          merit_desc(ipeak) = merit_min
          ! abuse prog_outputnr to store merit_min_id temporarily
          prog_outputnr(ipeak) = merit_min_id
        endif

        deallocate(particlelist, canddts, merit, part_local_ind)
      endif

    end subroutine find_prog_in_older_snapshots





    !=============================================
    subroutine search_main_desc_loop()
    !=============================================

      !-----------------------------------------------------
      ! This subroutine finds a main descant for all
      ! progenitors during the treemaking loop.
      ! For every progenitor that hasn't found a match yet,
      ! it checks all possible candidates. If no candidate 
      ! is found, assume progenitor is merged into best 
      ! candidate.
      ! Results are communicated globally in the end.
      !-----------------------------------------------------
      
      use clfind_commons
      implicit none

      integer :: iprog, idl
      logical :: is_first
      integer :: store_id

      !----------------------------------------------------------------------
      ! update to_iter_prog array for every loop: Check whether they still
      ! need to be updated
      !----------------------------------------------------------------------

      do iprog = 1, nprogs
        if (to_iter_prog(iprog)) then
          if (main_desc(iprog)>0) then
            ! to_iter_prog(iprog): only re-check those that aren't finished
            ! main_desc(iprog) > 0: only check those that aren't considered to have merged
            ! (mergers need to be re-checked every time)
            call get_local_peak_id(main_desc(iprog), idl) 
            if (iprog==main_prog(idl)) then
              to_iter_prog(iprog) = .false.
            endif
          endif
        endif
      enddo


      !--------------------------------------------------------------
      ! Check all candidates of still available progenitors. 
      ! If no match is found, mark the progenitor as merged into the
      ! best candidate.
      !--------------------------------------------------------------

      is_first = .true.
      iprog = 1
      store_id = 0

      do while (iprog <= nprogs)

        if (to_iter_prog(iprog)) then
          if (is_first) then
            ! store id of best initial match; only for first iteration of each prog per loop
            store_id = abs(main_desc(iprog))

            ! reset values of all candidates for loop
            ! candidates that have been checked already will get negative tracer numbers
            if (p2d_links%cnt(iprog) > 0) then
              ipeak = p2d_links%first(iprog)
              do i = 1, p2d_links%cnt(iprog)
                if (p2d_links%ntrace(ipeak) < 0) p2d_links%ntrace(ipeak)=-p2d_links%ntrace(ipeak)
                ipeak = p2d_links%next(ipeak)
              enddo
            endif
          endif

          is_first = .true.
          to_iter_prog(iprog) = .false.

          call find_main_desc(iprog, found)

          ! if you found another candidate:
          if (found) then
            ! if found, then main_desc(iprog) > 0
            call get_local_peak_id(main_desc(iprog), idl)
            if (iprog/=main_prog(idl)) then
              ! if the new candidate still doesn't match: need to re-iterate
              to_iter_prog(iprog) = .true.
              ! mark this descendant as already checked
              call fill_matrix(p2d_links, iprog, main_desc(iprog), 0, 'inv')
              is_first = .false.
              iprog = iprog - 1 ! check this iprog again
            ! else
            !   to_iter_prog(iprog) = .false. anyways
            endif
          else
            ! if nothing found, assume progenitor merged into descendant
            main_desc(iprog) = store_id + peakshift
            ! check this one again next round
            to_iter_prog(iprog) = .true.
          endif

        endif ! to_iter_prog
        iprog = iprog + 1

      enddo



#ifndef WITHOUTMPI
      !---------------------------
      ! Communicate results. 
      !---------------------------
      do iprog = 1, nprogs
        if (prog_owner(iprog)/=myid) main_desc(iprog) = 0
      enddo
      call MPI_ALLREDUCE(MPI_IN_PLACE, main_desc, nprogs, MPI_INT, MPI_MAX, MPI_COMM_WORLD, i)
#endif

      ! revert peakshift
      do iprog = 1, nprogs
        if (main_desc(iprog)>peakshift) main_desc(iprog) = -(main_desc(iprog)-peakshift) ! make it negative!
      enddo

      return

    end subroutine search_main_desc_loop





    !=================================================
    subroutine search_main_prog_loop(reiter)
    !=================================================

      !----------------------------------------------------
      ! This subroutine finds a main progenitors for all 
      ! descendants during the treemaking loop.
      ! For evey descendant that hasn't found a match yet,
      ! it checks only the next best candidate. If no
      ! candidate is found, assume clump is newly formed.
      ! Results are communicated globally in the end.
      !----------------------------------------------------

      use clfind_commons
      implicit none

      logical, intent(inout) :: reiter ! whether loop needs to be repeated.

      integer :: ipeak, idl, hfreestart
      logical :: found

      merit_desc = 0 ! is array!

      do ipeak = 1, hfree-1
        if ( to_iter(ipeak) ) then ! if there is something to check for
          idl = 0
          if (main_prog(ipeak)>0) then
            if (main_desc(main_prog(ipeak))/=0) then
              ! abs needed here: mergers are signified by a negative main descendant ID
              call get_local_peak_id(abs(main_desc(main_prog(ipeak))), idl)
            endif
          endif
          if (ipeak /= idl) then
            ! if this descendant is not main descendant
            ! of its own main progenitor, look for next best candidate
            call find_main_prog(ipeak, merit_desc, found)
            if (found) then 
              ! mark the one you found
              call fill_matrix(d2p_links, ipeak, main_prog(ipeak), 0, 'inv')
            ! else
              ! if you run out of candidates:
              ! main_prog(ipeak) = 0 ! is done in find_main_prog()
            endif

          endif ! ipeak /= idl
        endif
      enddo



#ifndef WITHOUTMPI
      !---------------------------------------------
      ! Communicate results
      !---------------------------------------------

      ! communicate merits, find max
      merit_desc_copy = merit_desc
      call build_peak_communicator()
      call virtual_peak_dp(merit_desc(:), 'max')
      call boundary_peak_dp(merit_desc(:))

      do ipeak = 1, hfree-1
        ! if you didn't have the max, reset stuff
        if (merit_desc_copy(ipeak) < merit_desc(ipeak) .and. main_prog(ipeak)/=0) then
          ! reset mark in matrix for later use
          call fill_matrix(d2p_links, ipeak, main_prog(ipeak), 0, 'inv')
          ! reset value in array
          main_prog(ipeak) = 0
        endif
      enddo

      ! call build_peak_communicator()
      call virtual_peak_int(main_prog, 'max')
      call boundary_peak_int(main_prog)

      ! check whether you need to reiterate peak first, while you have data
      ! synchronized globally
      hfreestart = hfree-1
      do ipeak = 1, hfreestart
        if (to_iter(ipeak)) then
          ! If there still is a main progenitor after communications, 
          ! check whether you still need to iterate
          if (main_prog(ipeak)>0) then
            if (main_desc(main_prog(ipeak))/=0) then
              ! abs needed here: mergers are signified by a negative main descendant ID
              call get_local_peak_id(abs(main_desc(main_prog(ipeak))), idl)
            else
              idl=0
            endif
            if (ipeak == idl) then
              to_iter(ipeak) = .false.
            else
              reiter = .true.
            endif
          else
            ! if there is no prog left after global sync, stop iterating this descendant.
            to_iter(ipeak) = .false.
          endif
        endif
      enddo

      ! In case you added new virtual peaks in the last loop, add them to list to work with.
      ! Otherwise, infinite loops might happen.
      if (hfree-1 > hfreestart .and. hfreestart>0) then
        do ipeak = hfreestart, hfree-1
          to_iter(ipeak) = .true.
        enddo
      endif
#endif

    end subroutine search_main_prog_loop


    !============================================
    subroutine dump_mergertree_debug()
    !============================================

      implicit none
      character(len=80)  :: fileloc
      character(len=5)   :: dir, idnr

      integer :: iprog, i, ipeak, ind


      call title(ifout, dir)
      call title(myid, idnr) 
      fileloc=TRIM('output_'//TRIM(dir)//'/debug_dump_mtree.txt'//TRIM(idnr))
      open(unit=666,file=fileloc,form='formatted')


      !-------------------------------------------------
      write(666,*) "UNFINISHED PROGENITORS"
      !-------------------------------------------------

      ! First finish up loop. Don't want to write stuff down that found a match in the last iteration
      call search_main_desc_loop()

      write(666,'(4(A15,x))') "iprog", "prog id", "main desc", "candidates"
      do iprog = 1, nprogs
        if (to_iter_prog(iprog)) then
          if (main_desc(iprog)>0) then
            write(666, '(4(I15,x))', advance='no') iprog, prog_id(iprog), main_desc(iprog), p2d_links%cnt(iprog)
            if (p2d_links%cnt(iprog) > 0) then
              ind = p2d_links%first(iprog)
              do i = 1, p2d_links%cnt(iprog)
                if (p2d_links%ntrace(ind) < 0) p2d_links%ntrace(ind)=-p2d_links%ntrace(ind)
                write(666,'(I10,":",I10," | ")',advance='no') p2d_links%clmp_id(ind), p2d_links%ntrace(ind)
                ind = p2d_links%next(ind)
              enddo
            endif
            write(666,*)
          endif
        endif
      enddo
      write(666,*)
      write(666,*)
      write(666,*)



      !-------------------------------------------------
      write(666,*) "UNFINISHED OWNED CLUMPS"
      !-------------------------------------------------
      write(666,'(6(A15,x))') "ipeak", "peak id", "main prog", "prog owner", "main desc of p", "candidates"
      do ipeak = 1, npeaks
        if (to_iter(ipeak)) then
          if (main_desc(main_prog(ipeak))/=0) then
            write(666, '(6(I15,x))', advance='no') ipeak, ipeak+ipeak_start(myid), prog_id(main_prog(ipeak)), &
              prog_owner(main_prog(ipeak)), main_desc(main_prog(ipeak)), d2p_links%cnt(ipeak)
            if (d2p_links%cnt(ipeak) > 0) then
              ind = d2p_links%first(ipeak)
              do i = 1, d2p_links%cnt(ipeak)
                if (d2p_links%ntrace(ind) < 0) d2p_links%ntrace(ind)=-d2p_links%ntrace(ind)
                write(666,'(I10,":",I10," | ")',advance='no') prog_id(d2p_links%clmp_id(ind)), d2p_links%ntrace(ind)
                ind = d2p_links%next(ind)
              enddo
            endif
            write(666,*)
          endif
        endif
      enddo
      write(666,*)
      write(666,*)
      write(666,*)



      !-------------------------------------------------
      write(666,*) "UNFINISHED VIRTUAL CLUMPS"
      !-------------------------------------------------
      write(666,'(6(A15,x))') "ipeak", "peak id", "main prog", "prog owner", "main desc of p", "candidates"
      do ipeak = npeaks+1, hfree-1
        if (to_iter(ipeak)) then
          if (main_desc(main_prog(ipeak))/=0) then
            write(666, '(6(I15,x))', advance='no') ipeak, ipeak+ipeak_start(myid), prog_id(main_prog(ipeak)),& 
              prog_owner(main_prog(ipeak)), main_desc(main_prog(ipeak)), d2p_links%cnt(ipeak)
            if (d2p_links%cnt(ipeak) > 0) then
              ind = d2p_links%first(ipeak)
              do i = 1, d2p_links%cnt(ipeak)
                if (d2p_links%ntrace(ind) < 0) d2p_links%ntrace(ind)=-d2p_links%ntrace(ind)
                write(666,'(I10,":",I10," | ")',advance='no') prog_id(d2p_links%clmp_id(ind)), d2p_links%ntrace(ind)
                ind = d2p_links%next(ind)
              enddo
              write(666,*)
            endif
          endif
        endif
      enddo

      close(666)

    end subroutine dump_mergertree_debug 


end subroutine make_trees








!====================================
subroutine read_progenitor_data()
!====================================
  
  !---------------------------------
  ! Reads in all progenitor data
  !---------------------------------

  use clfind_commons
  use amr_commons
  use mpi_mod

  implicit none

  integer           :: prog_read, prog_read_local, startind, tracer_free
  integer           :: nprogs_to_read, progcount_to_read, np
  integer           :: iprog, i
  character(LEN=80) :: fileloc
  character(LEN=5)  :: output_to_string, id_to_string
  logical           :: exists

  integer, allocatable, dimension(:) :: read_buffer_int   ! temporary array for reading in data
  real(dp),allocatable, dimension(:) :: read_buffer_real  ! temporary array for reading in data
  real(dp),allocatable, dimension(:) :: read_buffer_mpeak ! temporary array for reading in mock galaxy data
  integer, allocatable, dimension(:) :: buffer_int_all    ! collective data 
  real(dp),allocatable, dimension(:) :: buffer_real_all   ! collective data 
  real(dp),allocatable, dimension(:) :: buffer_mpeak_all  ! collective data 

#ifndef WITHOUTMPI
  integer                            :: mpi_err
  integer, allocatable, dimension(:) :: recvcount, displacements
#endif

  if (verbose) write(*,*) " Calling read progenitor data."

  call title(ifout-1, output_to_string)
  call title(myid, id_to_string)
  ! ifout -1: read from previous output!
  nprogs = 0
  nprogs_to_read = 0
  progcount_to_read = 0


  !==================================
  ! READ CURRENT PROGENITOR DATA
  !==================================


  !--------------------------------
  ! Read progenitor particles
  !--------------------------------

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/progenitor_data_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

  inquire(file=fileloc, exist=exists)
  if (.not.exists) then
    write(*,*) "ID", myid, "didn't find file ", fileloc
    call clean_stop
  endif

  open(unit=666,file=fileloc,form='unformatted')
  read(666) np                  ! number of unique progenitors in this file
  read(666) progcount_to_read   ! number of integers that needs to be read
  if (progcount_to_read>0) then
    allocate(read_buffer_int(1:progcount_to_read))
    read(666) read_buffer_int
  else
    ! safety measure
    allocate(read_buffer_int(1:1))
    read_buffer_int = 0
  endif
  close(666)




  !--------------------------------
  ! Read progenitor masses
  !--------------------------------

  if (progcount_to_read > 0) then 

    fileloc=TRIM('output_'//TRIM(output_to_string)//'/progenitor_mass_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

    inquire(file=fileloc, exist=exists)
    if (.not.exists) then
      write(*, *) "ID", myid, "didn't find file ", fileloc
      call clean_stop
    endif

    open(unit=666,file=fileloc,form='unformatted')
    read(666) nprogs_to_read    ! number of progenitors, virtual and not, in this file
    allocate(read_buffer_real(1:nprogs_to_read))
    read(666) read_buffer_real
    if (make_mock_galaxies) then
      allocate(read_buffer_mpeak(1:nprogs_to_read))
      read(666) read_buffer_mpeak
    endif
    close(666)
  
  else
    
    ! safety measure
    allocate(read_buffer_real(1:1))
    read_buffer_real = 0
    if (make_mock_galaxies) then
      allocate(read_buffer_mpeak(1:1))
      read_buffer_mpeak = 0
    endif

  endif



  !-------------------------------
  ! Share the data you just read
  !-------------------------------

#ifndef WITHOUTMPI
  allocate(recvcount(1:ncpu))
  allocate(displacements(1:ncpu))


  ! Communicate progenitor data
  !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  call MPI_ALLGATHER(progcount_to_read, 1, MPI_INT, recvcount, 1, MPI_INT, MPI_COMM_WORLD, mpi_err)
  ! overwrite progcount_to_read with total number of integers in common array
  progcount_to_read = sum(recvcount)

  displacements=0
  do i=1, ncpu-1
    displacements(i+1) = displacements(i) + recvcount(i)
  enddo

  allocate(buffer_int_all(1:progcount_to_read))
  call MPI_ALLGATHERV(read_buffer_int, recvcount(myid), MPI_INT, buffer_int_all, recvcount, displacements, MPI_INT, MPI_COMM_WORLD, mpi_err)


  ! Communicate progenitor masses
  !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  call MPI_ALLGATHER(nprogs_to_read, 1, MPI_INT, recvcount, 1, MPI_INT, MPI_COMM_WORLD, mpi_err)
  ! overwrite progcount_to_read with total number of integers in common array
  nprogs_to_read = sum(recvcount)

  displacements=0
  do i=1, ncpu-1
    displacements(i+1) = displacements(i) + recvcount(i)
  enddo

  allocate(buffer_real_all(1:nprogs_to_read))
  call MPI_ALLGATHERV(read_buffer_real, recvcount(myid), MPI_DOUBLE, &
    buffer_real_all, recvcount, displacements,  MPI_DOUBLE, MPI_COMM_WORLD, mpi_err)


  if (make_mock_galaxies) then
    allocate(buffer_mpeak_all(1:nprogs_to_read))
    call MPI_ALLGATHERV(read_buffer_mpeak, recvcount(myid), MPI_DOUBLE, &
      buffer_mpeak_all, recvcount, displacements, MPI_DOUBLE, MPI_COMM_WORLD, mpi_err)
  endif

#else

  allocate(buffer_int_all(1:progcount_to_read))
  buffer_int_all = read_buffer_int
  allocate(buffer_real_all(1:nprogs_to_read))
  buffer_real_all = read_buffer_real
  if (make_mock_galaxies) then
    allocate(buffer_mpeak_all(1:nprogs_to_read))
    buffer_mpeak_all = read_buffer_mpeak
  else
    ! safety measure
    allocate(buffer_mpeak_all(1:1))
    buffer_mpeak_all = 0
  endif

#endif
  
  deallocate(read_buffer_int, read_buffer_real, read_buffer_mpeak)




  !---------------------------
  ! Allocate arrays
  !---------------------------

  ! Communicate how many progenitors you have in total for clean array allocation
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(np, nprogs, 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD, mpi_err)
#else
  nprogs = np
#endif

  allocate(prog_id(1:nprogs))
  prog_id = 0       ! list of progenitor global IDs
  prog_free = 1     ! first free local progenitor ID

  allocate(prog_owner(1:nprogs))
  prog_owner = -1

  allocate(prog_mass(1:nprogs))
  prog_mass = 0

  allocate(tracers_all(1:nprogs*nmost_bound))
  tracers_all = 0

  allocate(galaxy_tracers(1:nprogs))

  allocate(tracer_loc_progids_all(1:nprogs*nmost_bound))
  tracer_loc_progids_all = 0
  tracer_free = 1   ! first free local tracer index

  if (make_mock_galaxies) then
    i = nprogs
  else
    ! just to prevent "may be uninitialized" warnings
    i = 1
  endif
  allocate(prog_mpeak(1:i))
  prog_mpeak = 0



  if (nprogs > 0) then

    !----------------------------------
    ! Sort out the data you just read
    !----------------------------------

    tracer_free = 1
    iprog = 1
    startind = 1

    do while (startind <= progcount_to_read)

      prog_read = buffer_int_all(startind)
      np = buffer_int_all(startind + 1)

      ! get local instead global ID in prog_read (past tense "read")
      call get_local_prog_id(prog_read, prog_read_local)

      prog_mass(prog_read_local) = buffer_real_all(iprog)
      if (make_mock_galaxies) then
        prog_mpeak(prog_read_local) = buffer_mpeak_all(iprog)
      endif

      do i = startind+2, startind+1+np
        if (buffer_int_all(i) > 0) then
          tracers_all(tracer_free) = buffer_int_all(i)               ! add new tracer particle
          tracer_loc_progids_all(tracer_free) = prog_read_local   ! write which progenitor tracer belongs to
          tracer_free = tracer_free + 1                           ! raise index for next tracer
        else 
          ! found a galaxy particle
          tracers_all(tracer_free) = -buffer_int_all(i)              ! add new tracer particle
          galaxy_tracers(prog_read_local) = -buffer_int_all(i)       ! add new galaxy tracer
          tracer_loc_progids_all(tracer_free) = prog_read_local   ! write which progenitor tracer belongs to
          tracer_free = tracer_free + 1                           ! raise index for next tracer
        endif
      enddo

      iprog = iprog + 1
      startind = startind + 2 + np

    enddo

  endif ! nprogs > 0

  deallocate(buffer_int_all, buffer_real_all)
  if (make_mock_galaxies) deallocate(buffer_mpeak_all)




  !========================================
  ! READ PAST PROGENITOR DATA
  !========================================

  !-----------------------------
  ! Read in data
  !-----------------------------

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/past_merged_progenitors_data_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

  open(unit=666,file=fileloc,form='unformatted')
  read(666) np ! number of integers that need to be read
  if (np > 0) then
    allocate(read_buffer_int(1:np))
    read(666) read_buffer_int
  else
    allocate(read_buffer_int(1:1))
    read_buffer_int = 0
  endif
  close(666)


  !---------------------------------
  ! Read past progenitor's masses
  !---------------------------------

  if (np > 0) then

    fileloc=TRIM('output_'//TRIM(output_to_string)//'/past_merged_progenitors_mass_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

    inquire(file=fileloc, exist=exists)
    if (.not.exists) then
      write(*, *) "ID", myid, "didn't find file ", fileloc
      call clean_stop
    endif

    open(unit=666,file=fileloc,form='unformatted')
    read(666) npastprogs ! number of pmprog masses in this file; also the number of unique pmprogs in this file.
    if (npastprogs>0) then
      allocate(read_buffer_real(1:npastprogs))
      read(666) read_buffer_real
      if (make_mock_galaxies) then
        allocate(read_buffer_mpeak(1:npastprogs))
        read(666) read_buffer_mpeak 
      endif
    endif
    close(666)

  else 

    ! safety measure
    allocate(read_buffer_real(1:1))
    read_buffer_real = 0
    if (make_mock_galaxies) then
      allocate(read_buffer_mpeak(1:npastprogs))
      read_buffer_mpeak = 0
    endif

  endif



  !-------------------------------
  ! Share the data you just read
  !-------------------------------

#ifndef WITHOUTMPI

  ! Communicate past merged progenitor data
  !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  call MPI_ALLGATHER(np, 1, MPI_INT, recvcount, 1, MPI_INT, MPI_COMM_WORLD, mpi_err)
  ! overwrite progcount_to_read with total number of integers in common array
  progcount_to_read = sum(recvcount)

  displacements=0
  do i=1, ncpu-1
    displacements(i+1) = displacements(i) + recvcount(i)
  enddo

  allocate(buffer_int_all(1:progcount_to_read))
  call MPI_ALLGATHERV(read_buffer_int, recvcount(myid), MPI_INT, &
    buffer_int_all, recvcount, displacements, MPI_INT, MPI_COMM_WORLD, mpi_err)


  ! Communicate past merged progenitor masses
  !~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  call MPI_ALLGATHER(npastprogs, 1, MPI_INT, recvcount, 1, MPI_INT, MPI_COMM_WORLD, mpi_err)
  ! overwrite npastprogs with total number of integers in common array
  npastprogs = sum(recvcount)

  displacements=0
  do i=1, ncpu-1
    displacements(i+1) = displacements(i) + recvcount(i)
  enddo

  ! overestimate size to fit new ones if necessary
  npastprogs_max = npastprogs + nprogs

  ! past merged progenitor mass
  allocate(pmprogs_mass(1:npastprogs_max))
  pmprogs_mass = 0

  call MPI_ALLGATHERV(read_buffer_real, recvcount(myid), MPI_DOUBLE,&
    pmprogs_mass, recvcount, displacements, MPI_REAL, MPI_COMM_WORLD, mpi_err)

  if (make_mock_galaxies) then
    allocate(pmprogs_mpeak(1:npastprogs_max))
    pmprogs_mpeak = 0

    call MPI_ALLGATHERV(read_buffer_mpeak, recvcount(myid), MPI_DOUBLE, &
      pmprogs_mpeak, recvcount, displacements, MPI_DOUBLE, MPI_COMM_WORLD, mpi_err)
  endif

#else

  ! overestimate size to fit new ones if necessary
  npastprogs_max = npastprogs + nprogs

  allocate(pmprogs_mass(1:npastprogs_max))
  pmprogs_mass = 0
  pmprogs(1:npastprogs) = read_buffer_real(1:npastprogs)

  if (make_mock_galaxies) then
    allocate(pmprogs_mpeak(1:npastprogs_max))
    pmprogs_mpeak = 0
    pmprogs_mpeak = read_buffer_mpeak(1:npastprogs)
  endif

#endif
  




 
  !-------------------------
  ! Allocate arrays
  !-------------------------

  pmprog_free = npastprogs + 1

  ! Past Merged Progenitors for multi-snapshot matching
  allocate(pmprogs(1:npastprogs_max))
  pmprogs = 0 

  ! Current owner Merged Progenitors' galaxy particles
  allocate(pmprogs_owner(1:npastprogs_max))
  pmprogs_owner = 0

  ! Past Merged Progenitors' galaxy particles
  allocate(pmprogs_galaxy(1:npastprogs_max))
  pmprogs_galaxy = 0

  ! Time at which past progenitors have been merged (= ifout at merging time)
  allocate(pmprogs_t(1:npastprogs_max))
  pmprogs_t = 0


  if (npastprogs > 0) then

    !----------------------------------
    ! Sort out the data you just read
    !----------------------------------

    pmprog_free = 1
    iprog = 1
    do while (iprog <= 3*npastprogs)
      pmprogs(pmprog_free) = buffer_int_all(iprog)
      pmprogs_galaxy(pmprog_free) = buffer_int_all(iprog + 1)
      pmprogs_t(pmprog_free) = buffer_int_all(iprog + 2)
      iprog = iprog + 3
      pmprog_free = pmprog_free + 1
    enddo

    deallocate(buffer_int_all)

  endif ! npastprogs > 0

end subroutine read_progenitor_data







!=============================
subroutine write_trees()
!=============================

  !-------------------------------
  ! Write the tree to file
  !-------------------------------

  use clfind_commons
  use mpi_mod

  implicit none

#ifndef WITHOUTMPI
  integer :: err
#endif

  character(len=5)             :: dir, idnr
  character(len=80)            :: fileloc
  integer                      :: ipeak, iprog
  real(dp)                     :: npartclump, clumpmass
  logical, dimension(1:nprogs) :: printed

  if (verbose) write(*,*) " writing trees to file."

  printed = .false.

  call title(ifout, dir)
  call title(myid, idnr) 
  fileloc=TRIM('output_'//TRIM(dir)//'/mergertree_'//TRIM(dir)//'.txt'//TRIM(idnr))

  open(unit=666,file=fileloc,form='formatted')
  write(666, '(3(A15),8(A18))') &
    "clump", "progenitor", "prog outputnr", &
    "desc mass", "desc npart", &
    "desc x", "desc y", "desc z", &
    "desc vx", "desc vy", "desc vz"
  !----------------------------------
  ! Possible cases:
  ! 1: adjacent link found
  ! 2: no link or new clump found
  ! 3: non-adjacent link found
  ! 4: merging detected
  !----------------------------------


  do ipeak = 1, npeaks
    if (clmp_mass_exclusive(ipeak) > 0) then

      if (use_exclusive_mass) then
        clumpmass = clmp_mass_exclusive(ipeak)
      else
        clumpmass = clmp_mass_pb(ipeak)
      endif
      npartclump = clumpmass/partm_common

      !----------------------
      ! Adjacent link found
      !----------------------
      if (main_prog(ipeak) > 0 ) then
        write(666,'(3(I15), 8(E18.10))') &
          ipeak+ipeak_start(myid), prog_id(main_prog(ipeak)), prog_outputnr(ipeak), &
          clumpmass, npartclump,&
          peak_pos(ipeak,1), peak_pos(ipeak,2), peak_pos(ipeak,3), &
          clmp_vel_pb(ipeak,1), clmp_vel_pb(ipeak,2), clmp_vel_pb(ipeak,3)
        printed(main_prog(ipeak)) = .true.


      !------------------------------
      ! No link or new clump found
      !------------------------------
      else if (main_prog(ipeak) == 0) then
        write(666,'(3(I15), 8(E18.10))') &
          ipeak+ipeak_start(myid), 0, ifout-1, &
          clumpmass, npartclump,&
          peak_pos(ipeak,1), peak_pos(ipeak,2), peak_pos(ipeak,3), &
          clmp_vel_pb(ipeak,1), clmp_vel_pb(ipeak,2), clmp_vel_pb(ipeak,3)


      !----------------------------------------------
      ! Progenitor from non-adjacent snapshot found
      !----------------------------------------------
      else 
        write(666,'(3(I15), 8(E18.10))') &
          ipeak+ipeak_start(myid), main_prog(ipeak), prog_outputnr(ipeak), &
          clumpmass, npartclump,&
          peak_pos(ipeak,1), peak_pos(ipeak,2), peak_pos(ipeak,3), &
          clmp_vel_pb(ipeak,1), clmp_vel_pb(ipeak,2), clmp_vel_pb(ipeak,3)
      endif
    endif
  enddo


#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(MPI_IN_PLACE, printed, nprogs, MPI_LOGICAL, MPI_LOR, MPI_COMM_WORLD, err)
#endif



  !-----------------------------
  ! Merged progenitors
  !-----------------------------

  ! Print whatever hasn't been printed yet.
  ! If a progenitor merged with another into a composite descendant, the non-main progenitor
  ! will have a negative main descendant ID.
  do iprog = 1, nprogs
    if ( (.not.printed(iprog)) .and. main_desc(iprog) /= 0 .and. prog_owner(iprog) == myid ) then
      ! don't print desc data for this case. Just fill up with 0s
      write(666, '(3(I15),8(I18))') main_desc(iprog), prog_id(iprog), ifout-1, 0,0,0,0,0,0,0,0 
    endif
  enddo


  close(666)

end subroutine write_trees






!======================================
subroutine write_progenitor_data()
!======================================

  !--------------------------------------------
  ! This subroutine writes the formatted and
  ! unformatted output needed for mergertrees.
  !--------------------------------------------

  use clfind_commons
  use amr_commons
  use pm_commons, only: idp
  use mpi_mod

  implicit none

  integer,  allocatable, dimension(:) :: particlelist, pastproglist
  real(dp), allocatable, dimension(:) :: masslist, pastprogmasslist
  real(dp), allocatable, dimension(:) :: mpeaklist ! mass at accretion for subhalos
  real(dp), allocatable, dimension(:) :: pastprogmpeaklist ! stellar masses of past merged progs

  character(LEN=80) :: fileloc
  character(LEN=5)  :: output_to_string, id_to_string 
  integer           :: ipeak, ipart, pind, startind, first_bound, partcount
  integer           :: ihalo, haloid, npastprogs_all

#ifndef WITHOUTMPI
  integer                                :: mpi_err
#endif

#ifdef MTREEDEBUG
  integer, dimension(1:4)                :: buf
  call mtreedebug_dump_mostbound_lists()
#endif



  !=======================================================
  ! Write current clumps as progenitors for next snapshot 
  !=======================================================

  call title(ifout, output_to_string)
  call title(myid, id_to_string)

  !------------------------------------------------------------------------------
  ! Prepare particle list
  ! Format: haloID, number of tracers written, [specified nr of particle IDs]
  !------------------------------------------------------------------------------

  ihalo = 0           ! count how many clumps you're actually writing 
  progenitorcount = 0
  pind = 1            ! index where to write

  ! progenitorcount_written is local to each CPU at this point
  ! and overestimated to surely have enough array length

  allocate(particlelist(1:progenitorcount_written*(nmost_bound+2)))
  particlelist = 0
  allocate(masslist(1:progenitorcount_written))
  masslist = 0

  if (make_mock_galaxies) then
    ipart = progenitorcount_written
  else
    ! just to prevent "may be uninitialized" warnings
    ipart = 1
  endif
  allocate(mpeaklist(1:ipart))
  mpeaklist = 0

  if (progenitorcount_written > 0) then

    do ipeak = 1, hfree-1
      ! write only peaks that have most bound particles
      if (clmp_mass_exclusive(ipeak) > 0 ) then

        haloid = 0
        first_bound = 0
        partcount = 0
        if (ipeak <= npeaks) progenitorcount = progenitorcount + 1 ! count only non-virtuals
      
        do ipart = 1, nmost_bound
          ! check if there are mostbound particles for this clump on this CPU 
          if (most_bound_pid(ipeak, ipart) > 0) then
            first_bound = ipart
            ! most bound particles are marked with negative clump id!
            haloid = abs(clmpidp(most_bound_pid(ipeak, ipart)))
            exit
          endif
        enddo

        ! If there are mostbound particles on this CPU:
        if (first_bound > 0) then
          ihalo = ihalo + 1

          startind = pind                                 ! starting index to write in array
          particlelist(startind) = haloid                 ! store halo ID at [startind]
          pind = pind + 2                                 ! move first free index in array to be written to file
          if (use_exclusive_mass) then
            masslist(ihalo) = clmp_mass_exclusive(ipeak)  ! store mass at first free halo position
          else
            masslist(ihalo) = clmp_mass_pb(ipeak)
          endif

          if (make_mock_galaxies) then                    ! store mass and a_exp at accretion
            mpeaklist(ihalo) = mpeak(ipeak)
          endif


          ! loop over mostbound particle list
          do ipart = first_bound, nmost_bound
            ! write only halos that have mbp on this proc
            if (most_bound_pid(ipeak, ipart) > 0) then
              partcount = partcount + 1
              if (ipart == 1) then ! if galaxy particle: mark it
                particlelist(pind) = -idp(most_bound_pid(ipeak, ipart))
              else !if regular most bound particle
                particlelist(pind) = idp(most_bound_pid(ipeak, ipart))
              endif
              pind = pind + 1

            endif
          enddo

          particlelist(startind + 1) = partcount        ! store number of particles written at [startind+1]
        endif
      endif ! clump mass > 0
    enddo ! loop over clumps


    ! reset written progenitorcount: Too small clumps might've 
    ! been dissolved after being counted.
    ! furthermore, this is not the count of progenitors anymore, but
    ! the total count of integers written.
    progenitorcount_written = pind-1

  endif ! if there is potentially stuff to write

  !--------------------------------
  ! write mostbound particle list
  !--------------------------------

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/progenitor_data_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))
  open(unit=666,file=fileloc,form='unformatted')
  write(666) progenitorcount
  write(666) progenitorcount_written
  write(666) particlelist
  close(666)




  !--------------------------------
  ! write progenitor mass list
  !--------------------------------

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/progenitor_mass_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

  open(unit=666,file=fileloc,form='unformatted')
  write(666) ihalo
  write(666) masslist
  if (make_mock_galaxies) then
    write(666) mpeaklist
  endif
  close(666)


#ifdef MTREEDEBUG
  call mtreedebug_dump_written_progenitor_data(particlelist, progenitorcount_written, masslist, mpeaklist, ihalo)
#endif


  deallocate(particlelist)
  deallocate(masslist)
  if (make_mock_galaxies) deallocate(mpeaklist)




  !========================================
  ! Write past merged progenitors data
  !========================================

  !---------------------------------------------------------
  ! Write past merged progenitor IDs, their galaxy particle
  ! and their merging time
  ! Format:
  ! ID prog1, galaxy prog1, time prog1, ID prog2, ...
  !---------------------------------------------------------

  allocate(pastproglist(1:3*(pmprog_free-1)))
  pastproglist = 0
  allocate(pastprogmasslist(1:(pmprog_free-1)))
  pastprogmasslist = 0

  ! this is only to prevent "may be uninitialized" warnings
  if (make_mock_galaxies) then
    ipart = (pmprog_free-1)
  else
    ipart = 1
  endif
  allocate(pastprogmpeaklist(1:ipart))
  pastprogmpeaklist = 0


  npastprogs_all = 0 ! count how many pmprogs you write. 
  pind = 0

  ! If the past merged progenitor was used, the owner was overwritten to 0.
  ! Share that info before continuing.
#ifndef WITHOUTMPI
  if (npastprogs > 0) then
    call MPI_ALLREDUCE(MPI_IN_PLACE, pmprogs_owner, npastprogs, &
      MPI_INT, MPI_MIN, MPI_COMM_WORLD, ipeak)
  endif
#endif


  if (pmprog_free > 1) then ! if you have stuff to write
    do ipeak = 1, pmprog_free - 1

      ! Only write if you own this progenitor
      if (pmprogs_owner(ipeak)==myid) then 

        ! Only write if the progenitor hasn't merged too long ago
        if (max_past_snapshots > 0) then
          if ((ifout - pmprogs_t(ipeak)) <= max_past_snapshots) then
            pastproglist(pind+1) = pmprogs(ipeak)
            pastproglist(pind+2) = pmprogs_galaxy(ipeak)
            pastproglist(pind+3) = pmprogs_t(ipeak)
            pind = pind + 3
            npastprogs_all = npastprogs_all + 1
            pastprogmasslist(npastprogs_all) = pmprogs_mass(ipeak)
            if (make_mock_galaxies) then
              pastprogmpeaklist(npastprogs_all) = pmprogs_mpeak(ipeak)
            endif
          endif
        else
          pastproglist(pind+1) = pmprogs(ipeak)
          pastproglist(pind+2) = pmprogs_galaxy(ipeak)
          pastproglist(pind+3) = pmprogs_t(ipeak)
          pind = pind + 3
          npastprogs_all = npastprogs_all + 1
          pastprogmasslist(npastprogs_all) = pmprogs_mass(ipeak)
          if (make_mock_galaxies) then
            pastprogmpeaklist(npastprogs_all) = pmprogs_mpeak(ipeak)
          endif
        endif
      endif
    enddo
  endif

  ! henceforth, pind is the number of elements in the array to be written



  !-------------------------------------
  ! Write past merged progenitors list
  !-------------------------------------

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/past_merged_progenitors_data_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

  open(unit=666,file=fileloc,form='unformatted')
  write(666) pind
  write(666) pastproglist
  close(666)




  !-----------------------------------------
  ! Write past merged progenitors mass list
  !-----------------------------------------
  fileloc=TRIM('output_'//TRIM(output_to_string)//'/past_merged_progenitors_mass_'//TRIM(output_to_string)//'.dat'//TRIM(id_to_string))

  open(unit=666,file=fileloc,form='unformatted')
  write(666) pastprogmasslist
  if (make_mock_galaxies) then
    write(666) npastprogs_all
    write(666) pastprogmasslist
    write(666) pastprogmpeaklist
  endif
  close(666)

#ifdef MTREEDEBUG
  call  mtreedebug_dump_written_past_merged_progenitor_data(pastproglist, pind,& 
  pastprogmasslist, pastprogmpeaklist, npastprogs_all)
#endif

  deallocate(pastproglist, pastprogmasslist)




  !======================================
  ! Write number of progenitors to file
  ! (both current and past)
  !======================================

#ifdef MTREEDEBUG
  buf = (/progenitorcount, ihalo, progenitorcount_written, npastprogs_all/)
  call mtreedebug_dump_prog_metadata(buf, .false.)

#ifndef WITHOUTMPI
  buf = (/progenitorcount, ihalo, progenitorcount_written, npastprogs_all/)
  if (myid == 1) then
    call MPI_REDUCE(MPI_IN_PLACE, buf, 4, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, mpi_err)
    progenitorcount = buf(1)
    ihalo = buf(2)
    progenitorcount_written = buf(3)
    npastprogs_all = buf(4)
  else
    call MPI_REDUCE(buf, buf, 4, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, mpi_err)
  endif
#endif

  if (myid==1) call mtreedebug_dump_prog_metadata(buf, .true.) 
#endif

end subroutine write_progenitor_data





!===========================================
subroutine make_galaxies()
!===========================================
  
  !---------------------------------------------------
  ! This subroutine assigns stellar masses to haloes,
  ! subhaloes and orphans and writes it to file.
  !---------------------------------------------------

  use clfind_commons
  use pm_commons, only: xp, idp

  implicit none
  integer               :: ipeak, mbpart, iprog
  real(dp)              :: m_to_use, alpha, gam, delta, xi, loge, logM1, scale_m
  character(LEN=80)     :: fileloc
  character(LEN=5)      :: output_to_string, id_to_string 


  allocate(mpeak(1:npeaks_max))
  mpeak = 0

  ! if clmp_mass_pb hasn't been updated yet, do it
  if (use_exclusive_mass) call boundary_peak_dp(clmp_mass_pb(:))



  !----------------------------------------
  ! get masses and a_exp for all clumps
  !----------------------------------------

  if (nprogs == 0) then
    ! Might happen e.g. with dice, where there are haloes starting with first snapshot.
    ! Then no progenitor arrays are allocated at this point.
    mpeak(1:npeaks) = clmp_mass_pb(1:npeaks)
  else
    do ipeak = 1, npeaks
      if (clmp_mass_exclusive(ipeak) > 0) then
        if (is_namegiver(ipeak)) then
          ! main halo: track peak mass
          if (main_prog(ipeak) > 0) then
            if (clmp_mass_pb(ipeak) >= prog_mpeak(main_prog(ipeak))) then
              mpeak(ipeak) = clmp_mass_pb(ipeak)
            else
              mpeak(ipeak) = prog_mpeak(main_prog(ipeak))
            endif
          else
            ! if no progenitor data available: store new
            mpeak(ipeak) = clmp_mass_pb(ipeak)
          endif
        else
          ! if satellite and has a progenitor:
          if (main_prog(ipeak) > 0) then
            mpeak(ipeak) = prog_mpeak(main_prog(ipeak))
          else
            mpeak(ipeak) = clmp_mass_pb(ipeak)
          endif
        endif
      endif
    enddo
  endif

#ifndef WHITOUTMPI
  call boundary_peak_dp(mpeak)
#endif


  !--------------------------
  ! Prepare file
  !--------------------------

  call title(ifout, output_to_string)
  call title(myid, id_to_string)

  fileloc=TRIM('output_'//TRIM(output_to_string)//'/galaxies_'//TRIM(output_to_string)//'.txt'//TRIM(id_to_string))

  open(unit=666,file=fileloc,form='formatted')
  write(666,'(6(A20,x))') "Associated clump", "Stellar Mass [M_Sol]", "x", "y", "z", "Galaxy Particle ID"

  !--------------------------
  ! Write currently active
  !--------------------------

  call calc_stellar_mass_params(alpha, gam, delta, loge, logM1, xi, scale_m)

  do ipeak = 1, hfree-1
    if (clmp_mass_exclusive(ipeak)>0) then
      ! only do stuff if you have the most bound particle here
      if (most_bound_pid(ipeak, 1)>0) then 
        mbpart = most_bound_pid(ipeak,1) ! get local index of most bound particle
        if(is_namegiver(ipeak)) then
          m_to_use = clmp_mass_pb(ipeak)
        else
          m_to_use = mpeak(ipeak)
        endif
        write(666, '(I20,x,4(E20.12,x),I20)') -clmpidp(mbpart), &
          stellar_mass(m_to_use,alpha,gam,delta,loge,logM1,xi,scale_m), &
          xp(mbpart,1), xp(mbpart,2), xp(mbpart,3), idp(mbpart)
      endif
    endif
  enddo


  !--------------------------
  ! Write orphans
  !--------------------------

  do iprog = 1, pmprog_free-1
    if (pmprogs_owner(iprog)==myid) then
      mbpart = orphans_local_pid(iprog)
      write(666, '(I20,x,4(E20.12,x),I20)') 0, &
        stellar_mass(pmprogs_mpeak(iprog),alpha,gam,delta,loge,logM1,xi,scale_m),& 
        xp(mbpart,1), xp(mbpart,2), xp(mbpart,3), idp(mbpart)
    endif
  enddo

  close(666)

end subroutine make_galaxies







!=================================================
subroutine get_local_prog_id(global_id, local_id)
!=================================================
  
  use clfind_commons
  implicit none
  integer, intent(in)  :: global_id 
  integer, intent(out) :: local_id 
  integer              :: i

  !---------------------------------
  ! Gets the local progenitor ID
  ! given the global progenitor ID.
  !---------------------------------

  ! Check if prog is already included
  do i = 1, prog_free-1
    if (prog_id(i) == global_id) then
      local_id = i
      return
    endif
  enddo

  ! progenitor is not in there; Give him a new index
  i = prog_free ! save for later
  prog_id(i) = global_id
  prog_free = prog_free + 1
  local_id = i
  return

end subroutine get_local_prog_id 





!==================================================
subroutine fill_matrix(mat, key, tar, np, act)
!==================================================

  !----------------------------------------------------
  ! Performs given operation on matrix elements of
  ! prog-desc matrices.
  !
  ! clump key:    local id for progenitor (p2d_links),
  !               local id for descendant (d2p_links)
  ! clump target: local id for progenitor (p2d_links),
  !               global id for descendant (d2p_links)
  ! act:          what to do with matrix elements 
  !   act = 'add': add up
  !   act = 'set': don't add, just set
  !   act = 'inv': make value negative
  !   'add' and 'set' will introduce new entries if
  !   there wasn't one before, 'inv' won't.
  !----------------------------------------------------

  use clfind_commons

  implicit none

  integer,             intent(in)    :: key, tar, np
  character(len=3),    intent(in)    :: act
  type(prog_desc_mat), intent(inout) :: mat

  integer :: i, itar

  ! if there is no first value, 
  ! add new first value
  if (mat%cnt(key) == 0) then
    if (act/='inv') then
      mat%first(key) = mat%mat_free_ind
      mat%clmp_id(mat%mat_free_ind) = tar
      mat%cnt(key) = mat%cnt(key) + 1

      if (act=='add') then
        mat%ntrace(mat%mat_free_ind) = mat%ntrace(mat%mat_free_ind) + np
      else if (act=='set') then
        mat%ntrace(mat%mat_free_ind) = np
      endif

      mat%mat_free_ind = mat%mat_free_ind + 1
    endif
    return

  else
    ! Try to find a match first
    itar = mat%first(key)
    do i = 1, mat%cnt(key)
      ! If you found a match:
      if (mat%clmp_id(itar) == tar) then
        if (act=='add') then
          mat%ntrace(itar) = mat%ntrace(itar) + np
        else if (act=='set') then
          mat%ntrace(itar) = np
        else if (act=='inv') then
          mat%ntrace(itar) = -mat%ntrace(itar)
        endif
        return
      endif

      if (mat%next(itar) > 0) then
        ! cycle
        itar = mat%next(itar)
      else
        exit
      endif
    enddo
  endif



  ! if you didn't find anything, add new value
  if (act /= 'inv') then  
    mat%next(itar) = mat%mat_free_ind
    mat%clmp_id(mat%mat_free_ind) = tar
    mat%cnt(key) = mat%cnt(key) + 1
    if (act=='add') then
      mat%ntrace(mat%mat_free_ind) = mat%ntrace(mat%mat_free_ind) + np
    else if (act=='set') then
      mat%ntrace(mat%mat_free_ind) = np
    endif

    mat%mat_free_ind = mat%mat_free_ind + 1
  endif
  return

end subroutine fill_matrix







!======================================
subroutine deallocate_mergertree()
!======================================

  !---------------------------------
  ! Deallocate arrays for mergertree
  !---------------------------------

  use clfind_commons 
  implicit none


  if (ifout > 1) then

    deallocate(main_prog)
    deallocate(prog_outputnr)

    deallocate(prog_id)
    deallocate(prog_owner)
    deallocate(galaxy_tracers)
    deallocate(prog_mass)

    deallocate(pmprogs)
    deallocate(pmprogs_owner)
    deallocate(pmprogs_galaxy)
    deallocate(pmprogs_t)
    deallocate(pmprogs_mass)

    if (make_mock_galaxies) then
      deallocate(prog_mpeak)
      deallocate(pmprogs_mpeak)
    endif


    if (nprogs > 0) then

      deallocate(p2d_links%first)
      deallocate(p2d_links%cnt)
      deallocate(p2d_links%ntrace)
      deallocate(p2d_links%clmp_id)
      deallocate(p2d_links%next)

      deallocate(d2p_links%first)
      deallocate(d2p_links%cnt)
      deallocate(d2p_links%ntrace)
      deallocate(d2p_links%clmp_id)
      deallocate(d2p_links%next)
     
      deallocate(main_desc)

      if (make_mock_galaxies) then
        deallocate(prog_galaxy_local_id)
        deallocate(orphans_local_pid)
      endif

    else
      deallocate(tracers_all) 
      deallocate(tracer_loc_progids_all)
    endif

  endif

  if (npeaks_tot > 0 .and. make_mock_galaxies) deallocate(mpeak)

  deallocate(most_bound_energy)
  deallocate(most_bound_pid)
  deallocate(clmp_mass_exclusive)
  ! deallocate(clmp_vel_exclusive)

end subroutine deallocate_mergertree






!=====================================
subroutine mark_tracer_particles()
!=====================================

  !------------------------------------------------------------------
  ! goes through all clumps
  ! first determines most bound particles via mpi communications
  ! then marks all most bound particles by making their clumpid 
  ! negative
  !------------------------------------------------------------------
  use clfind_commons 
  use amr_commons 
  implicit none
  
  integer                           :: ipeak, ipart, i
  real(dp), dimension(1:npeaks_max) :: temp_energy
  temp_energy = HUGE(0d0)



  ! for each of nmost_bound particles
  do ipart = 1, nmost_bound 

    ! copy this particle of each clump in an array, communicate and find min
    do ipeak = 1, hfree -1
      temp_energy(ipeak) = most_bound_energy(ipeak, ipart)
    enddo

    call build_peak_communicator()
    call virtual_peak_dp(temp_energy(:), 'min')
    call boundary_peak_dp(temp_energy(:))


    do ipeak = 1, hfree -1
      ! need to check whether it is relevant clump. otherwise temp_energy == most_bound_energy = HUGE anyways
      if (clmp_mass_exclusive(ipeak) > 0d0) then 

        ! if this is true minimal value for this peak
        if (temp_energy(ipeak) == most_bound_energy(ipeak, ipart) ) then

          ! mark particle if it is bound
          if (most_bound_pid(ipeak,ipart) > 0) then
            clmpidp(most_bound_pid(ipeak, ipart)) = -clmpidp(most_bound_pid(ipeak, ipart))
          endif

        else
          ! move particle energy list one to the right
          ! so you won't miss true minimum at later checks

          do i = nmost_bound, ipart + 1, -1
            most_bound_energy(ipeak, i) = most_bound_energy(ipeak, i-1)
            most_bound_pid(ipeak, i) = most_bound_pid(ipeak, i-1)
          enddo 

          ! also reset value at this position
          most_bound_energy(ipeak, ipart) = HUGE(0d0)
          most_bound_pid(ipeak, ipart) = 0

        endif ! true minimum
      endif ! relevant clump
    enddo
  enddo

end subroutine mark_tracer_particles







#ifdef MTREEDEBUG

!=========================================================
subroutine mtreedebug_filename(namestring, filename)
!=========================================================
  !--------------------------------------------------
  ! generate a filename for debugging output
  ! it will add 'namestring' to a specific prefix
  !--------------------------------------------------
  use amr_commons, only: myid, ifout
  implicit none
  character(len=100), intent(out) :: filename
  character(len=*), intent(in)    :: namestring
  character(len=5)                :: id_to_string, output_to_string

  call title(ifout, output_to_string)
  call title(myid, id_to_string)
  filename = TRIM("output_"//output_to_string//"/debug_mtree-"//TRIM(namestring)//".txt"//id_to_string)

end subroutine mtreedebug_filename



!==============================================
subroutine mtreedebug_matrixcheck_prog(before)
!==============================================

  use amr_commons 
  use clfind_commons
  implicit none
  logical, intent(in) :: before
  integer :: iprog, idl, ipeak, i
  character(len=100) :: fname

  if (mtreedebug_no_matrix_dump_prog) return
  
  if (before) then
    call mtreedebug_filename('MATRIXCHECK_PROG_BEFORE_LOOP', fname)
    open(unit=666, file=fname, form='formatted')
    write(666,'(A30,x,I9)') "MATRIXCHECK PROG BEFORE LOOP ID", myid
  else
    call mtreedebug_filename('MATRIXCHECK_PROG_AFTER_LOOP', fname)
    open(unit=666, file=fname, form='formatted')
    write(666,'(A30,x,I9)') "MATRIXCHECK PROG AFTER LOOP ID", myid
  endif

  write(666, '(6A14)') "Prog", "local id", "nr of desc", "owner", "mass", "main desc"

  do iprog = 1, nprogs
    if (p2d_links%cnt(iprog) > 0) then
      write(666, '(4I14,E14.6,I14, A5)', advance='no') &
        prog_id(iprog), iprog, p2d_links%cnt(iprog), &
        prog_owner(iprog), prog_mass(iprog), main_desc(iprog), ' ||| '

      ipeak = p2d_links%first(iprog)
      do i = 1, p2d_links%cnt(iprog)
        call get_local_peak_id(p2d_links%clmp_id(ipeak), idl)
        write(666, '(A3,x,2(I9,x),A9,x,I9)', advance='no') "D:", p2d_links%clmp_id(ipeak), idl, &
          "tracers:", p2d_links%ntrace(ipeak)
        ipeak = p2d_links%next(ipeak)
      enddo
      write(666,*)
    endif
  enddo
  close(666)
end subroutine mtreedebug_matrixcheck_prog 



!==============================================
subroutine mtreedebug_matrixcheck_desc(before)
!==============================================

  use amr_commons 
  use clfind_commons
  implicit none
  logical, intent(in) :: before ! whether you're printing before or after treemaking
  integer :: iprog, ipeak, i
  character(len=100) :: fname

  if (mtreedebug_no_matrix_dump_prog) return

  if (before) then
    call mtreedebug_filename('MATRIXCHECK_DESC_BEFORE_LOOP', fname)
    open(unit=666, file=fname, form='formatted')
    write(666,'(A30,x,I9)') "MATRIXCHECK DESC BEFORE LOOP ID", myid
  else
    call mtreedebug_filename('MATRIXCHECK_DESC_AFTER_LOOP', fname)
    open(unit=666, file=fname, form='formatted')
    write(666,'(A30,x,I9)') "MATRIXCHECK DESC AFTER LOOP ID", myid
  endif

  write(666, '(6A14)') "Desc", "nr of progs", "mass", "main prog"

  do ipeak = 1, hfree-1
    if (d2p_links%cnt(ipeak) > 0) then
      write(666, '(2I14,E14.6,I14, A5)', advance='no') &
        ipeak, d2p_links%cnt(ipeak), clmp_mass_exclusive(ipeak), &
        main_prog(ipeak),  ' ||| '


      iprog = d2p_links%first(ipeak)
      do i = 1, d2p_links%cnt(ipeak)
        write(666, '(A3,x,I9,x,A9,x,I9)', advance='no') "P:", & 
          d2p_links%clmp_id(iprog), "tracers:", d2p_links%ntrace(iprog)
        iprog = d2p_links%next(iprog)
      enddo
      write(666,*)
    endif

  enddo
  close(666)
end subroutine mtreedebug_matrixcheck_desc 



!============================================================
subroutine mtreedebug_dump_unbinding_data(filename_add)
!============================================================

  use amr_commons
  use clfind_commons
  use pm_commons, only: idp

  implicit none
  character(len=*) :: filename_add  ! string to be added to filename, so you can
                                    ! create unique files from anywhere in unbinding
  integer :: ipeak, i, ipart, npart_loc

  integer, allocatable, dimension(:) :: global_id, npartstot
  character(len=100)   :: fname

  if ( mtreedebug_no_unbinding_dump ) return


  allocate(global_id(1:npeaks_max))
  global_id = 0
  allocate(npartstot(1:npeaks_max))
  npartstot = 0

  do ipeak=1, npeaks
    global_id(ipeak) = ipeak+ipeak_start(myid)
  enddo
  npartstot = nclmppart
  call boundary_peak_int(global_id(:))
  call virtual_peak_int(npartstot, 'sum')
  call boundary_peak_int(npartstot)

  call mtreedebug_filename('unbinding_dump_'//TRIM(filename_add), fname)

  open(666, file=fname, form='formatted')
  
  write(666, '(A, I5, A, I10)') 'Unbinding Data dump ID', myid, ' npeaks', npeaks
  write(666, '(2A12,x,A16,x,A12,x,A18,x,A12,x,A12,x,A12,x,A12)') "Clump ID", "local ID", "is halo correct?", &
    "parent", "excl mass", "nparts comp", "npartsown_l", "nclmppart", "nclmpparttot"

  do ipeak=1, hfree-1
    if (nclmppart(ipeak)>0) then
      npart_loc = 0
      ipart = clmppart_first(ipeak)
      do i = 1, nclmppart(ipeak)
        if (global_id(ipeak) == clmpidp(ipart)) npart_loc = npart_loc + 1
        ipart = clmppart_next(ipart)
      enddo

      if (.not. mtreedebug_no_unbinding_particle_dump) then
        write(666,'(2I12,x,L16,x,I12,x,E18.11,x,I12,x,I12,x,I12,x,I12)', advance='no') &
          global_id(ipeak), ipeak, is_namegiver(ipeak) .eqv. (global_id(ipeak)==new_peak(ipeak)), &
          new_peak(ipeak), clmp_mass_exclusive(ipeak), int(clmp_mass_exclusive(ipeak)/partm_common+0.5), &
          npart_loc, nclmppart(ipeak), npartstot(ipeak)

        ipart = clmppart_first(ipeak)
        do i=1, nclmppart(ipeak)
          if (global_id(ipeak) == clmpidp(ipart)) write(666, '(I12)', advance='no') idp(ipart) 
          ipart = clmppart_next(ipart)
        enddo
        write(666, *)
      else
        write(666,'(2I12,x,L16,x,I12,x,E18.11,x,I12,x,I12,x,I12,x,I12)') &
          global_id(ipeak), ipeak, is_namegiver(ipeak) .eqv. (global_id(ipeak)==new_peak(ipeak)), &
          new_peak(ipeak), clmp_mass_exclusive(ipeak), int(clmp_mass_exclusive(ipeak)/partm_common+0.5), &
          npart_loc, nclmppart(ipeak), npartstot(ipeak)
      endif

    endif
  enddo
  
  close(666)
  deallocate(global_id)

end subroutine mtreedebug_dump_unbinding_data





!==================================================================================================================
subroutine mtreedebug_dump_written_progenitor_data(particlelist, plist_int, masslist, mpeaklist, mlist_int)
!==================================================================================================================

  use amr_commons
  use clfind_commons
  implicit none
  integer, intent(in) :: plist_int, mlist_int
  integer, dimension(1:plist_int), intent(in) :: particlelist
  real(dp), dimension(1:mlist_int), intent(in) :: masslist, mpeaklist
  character(len=100) :: fname
  integer :: i, ipart, id, np, iprog

  if (mtreedebug_no_progdata_dump) return


  call mtreedebug_filename('WRITTEN_PROGENITOR_DATA', fname)
  open(unit=666, form='formatted', file=fname)
  write(666, '(A, I5)') "WRITTEN PROGENITOR DATA ID", myid
  write(666, '(6A12)') "Clump ID", "mass", "peak mass", "np","Galaxy?", "Particles"
  ! is only galaxy if <0

  i = 1
  iprog = 1 
  do while (i <= plist_int)
    id = particlelist(i)
    np = particlelist(i+1)
    if (make_mock_galaxies) then
      write(666, '(I12,2E12.4,I12)', advance='no') id, masslist(iprog), mpeaklist(iprog), np
    else
      write(666, '(I12,E12.4,A12,I12)', advance='no') id, masslist(iprog), "------", np
    endif

    if (.not. mtreedebug_no_progdata_particle_dump) then
      do ipart = i+2, i+1+np
        write(666, '(I12)', advance='no') particlelist(ipart)
      enddo
      write(666, *)
    endif

    iprog = iprog + 1
    i = i + 2 + np
  enddo
  close(666)
  
end subroutine mtreedebug_dump_written_progenitor_data



!==================================================================================================================
subroutine mtreedebug_dump_written_past_merged_progenitor_data(&
  particlelist, plist_int, masslist, mpeaklist, mlist_int)
!==================================================================================================================

  use amr_commons
  use clfind_commons
  implicit none
  integer, intent(in) :: plist_int, mlist_int
  integer, dimension(1:plist_int), intent(in) :: particlelist
  real(dp), dimension(1:mlist_int), intent(in) :: masslist, mpeaklist
  character(len=100) :: fname
  integer :: i, id, iprog, gal, st

  if (mtreedebug_no_pmprogdata_dump) return


  call mtreedebug_filename('WRITTEN_PAST_MERGED_PROGENITOR_DATA', fname)
  open(unit=666, form='formatted', file=fname)
  write(666, '(A, I5)') "WRITTEN PAST MERGED PROGENITOR DATA ID", myid
  write(666, '(5A12)') "ID", "mass", "peak mass", "Galaxy", "Snapshot"
  ! is only galaxy if <0

  i = 1
  iprog = 1 
  do while (i <= plist_int)
    id = particlelist(i)
    gal = particlelist(i+1)
    st = particlelist(i+2)
    if (make_mock_galaxies) then
      write(666, '(I12,2E12.4,I12,I12)') id, masslist(iprog), mpeaklist(iprog), gal, st
    else
      write(666, '(I12,E12.4,A12,I12,I12)') id, masslist(iprog), "------", gal, st
    endif

    iprog = iprog + 1
    i = i + 3
  enddo
  close(666)
  
end subroutine mtreedebug_dump_written_past_merged_progenitor_data


!=========================================================
subroutine mtreedebug_dump_prog_metadata(buf, collective)
!=========================================================

  implicit none
  integer, dimension(1:4), intent(in) :: buf
  logical, intent(in) :: collective ! whether it's after MPI reduce or not
  character(len=100) :: fname

  if (collective) then
    call mtreedebug_filename('prog_collective_metadata', fname)
    open(unit=666, file=fname, form='formatted')
    write(666, '(4A20)') "nprogs_tot", "total written progs", "prog integers written", "n_pmprogs"
  else
    call mtreedebug_filename('prog_metadata', fname)
    open(unit=666, file=fname, form='formatted')
    write(666, '(4A20)') "nonvirtual progs", "total progs", "prog integers written", "n_pmprogs"
  endif

  write(666, '(4I20)') buf(1), buf(2), buf(3), buf(4)
  close(666)

end subroutine mtreedebug_dump_prog_metadata


!===============================================
subroutine mtreedebug_dump_mostbound_lists()
!===============================================

  use amr_commons
  use clfind_commons
  use pm_commons, only: idp
  implicit none
  character(len=100) :: fname
  integer :: ipart, haloid, partcount, first_bound, ipeak, gal, temp

  if (mtreedebug_no_mostbound_lists) return 

  call mtreedebug_filename('mostbound_particles', fname)
  open(unit=666, file=fname, form='formatted')
  write(666, '(4A12)') "Clump_ID", "partcount", "first_bound", "galaxy" 

  do ipeak=1, hfree-1
    if (clmp_mass_exclusive(ipeak)>0) then
      haloid = -1
      first_bound = -1
      partcount = 0

      do ipart=1, nmost_bound
        if (most_bound_pid(ipeak, ipart) > 0) then
          first_bound = ipart
          haloid = abs(clmpidp(most_bound_pid(ipeak, ipart)))
          exit
        endif
      enddo
      
      do ipart=1, nmost_bound
        if (most_bound_pid(ipeak, ipart) > 0) partcount = partcount + 1
      enddo

      gal = 0
      if (first_bound == 1) gal = -idp(most_bound_pid(ipeak, 1))
      if (first_bound == -1) first_bound = nclmppart(ipeak)
      write(666, '(4I12)', advance='no') haloid, partcount, first_bound, gal
      do ipart=1, nmost_bound
        temp = most_bound_pid(ipeak, ipart)
        if (temp > 0) temp = idp(most_bound_pid(ipeak, ipart))
        write(666, '(I12)', advance='no') temp
      enddo
      write(666, '(A)') ""
    endif
  enddo

  close(666)

end subroutine mtreedebug_dump_mostbound_lists

! #endif for MTREEDEBUG
#endif



! #endif for NDIM == 3
#endif


