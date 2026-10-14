/*------------------------------------------------------------------------
    File        : compile-one.p
    Purpose     : Compile a single file passed in SESSION:PARAMETER and dump
                  EVERY compiler message (compile.p only shows the last one).
    Usage       : _progres -b -p compile-one.p -param "<file>;<srcDir>"
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cFile   AS CHARACTER NO-UNDO.
DEFINE VARIABLE cSrcDir AS CHARACTER NO-UNDO.
DEFINE VARIABLE cNetLib AS CHARACTER NO-UNDO.
DEFINE VARIABLE i       AS INTEGER   NO-UNDO.

ASSIGN
    cFile   = ENTRY(1, SESSION:PARAMETER, ";")
    cSrcDir = ENTRY(2, SESSION:PARAMETER, ";").

cNetLib = OS-GETENV("DLC":u) + "/tty/netlib/OpenEdge.Net.apl":u.
FILE-INFO:FILE-NAME = cNetLib.
IF FILE-INFO:FULL-PATHNAME = ? THEN
    cNetLib = OS-GETENV("DLC":u) + "/tty/netlib/OpenEdge.Net.pl":u.

PROPATH = cSrcDir + ",":u
        + OS-GETENV("DLC":u) + "/tty,":u
        + cNetLib + ",":u
        + PROPATH.

COMPILE VALUE(cFile) SAVE = FALSE NO-ERROR.

IF COMPILER:NUM-MESSAGES > 0 THEN
DO i = 1 TO COMPILER:NUM-MESSAGES:
    MESSAGE "MSG" i ":" COMPILER:GET-MESSAGE(i).
END.

IF ERROR-STATUS:ERROR THEN
    MESSAGE "ERRSTATUS:" ERROR-STATUS:GET-MESSAGE(1).

MESSAGE SUBSTITUTE("messages=&1 error=&2", COMPILER:NUM-MESSAGES, COMPILER:ERROR).
