# Start code for a Trice program (detrytus docs/trice.md): a program
# imports include/layout.s and then this file. spawnw starts a process
# at V_USER with a0 = argc, a1 = argv, gp = USER_GP and sp = USER_SP,
# which is already the call main(argc, argv); what main returns is the
# exit code.

        .section program, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw
_start: call  main
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
