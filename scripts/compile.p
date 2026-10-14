/*------------------------------------------------------------------------
    File        : compile.p
    Purpose     : CLI compile-all for the Luna backend. Walks Backend/src
                  recursively and compiles every .cls / .p / .w it finds
                  into Backend/build, preserving the package structure.
    Usage       : _progres -b -p compile.p -param "<srcDir>;<buildDir>"
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cSrcDir     AS CHARACTER NO-UNDO.
DEFINE VARIABLE cBuildDir   AS CHARACTER NO-UNDO.
DEFINE VARIABLE iNumFiles   AS INTEGER   NO-UNDO INITIAL 0.
DEFINE VARIABLE iNumErrors  AS INTEGER   NO-UNDO INITIAL 0.

DEFINE VARIABLE cSaveDir AS CHARACTER NO-UNDO.
DEFINE VARIABLE cNetLib  AS CHARACTER NO-UNDO.

/* OE 12.8+ ships the HTTP/WebHandler library as OpenEdge.Net.apl;
   OE 12.2 still ships it as OpenEdge.Net.pl. Pick whichever exists. */
cNetLib = OS-GETENV("DLC":u) + "/tty/netlib/OpenEdge.Net.apl":u.
FILE-INFO:FILE-NAME = cNetLib.
IF FILE-INFO:FULL-PATHNAME = ? THEN
    cNetLib = OS-GETENV("DLC":u) + "/tty/netlib/OpenEdge.Net.pl":u.

ASSIGN
    cSrcDir   = ENTRY(1, SESSION:PARAMETER, ";")
    cBuildDir = ENTRY(2, SESSION:PARAMETER, ";")
    PROPATH   = cSrcDir + ",":u
              + OS-GETENV("DLC":u) + "/tty,":u
              + cNetLib + ",":u
              + PROPATH
    .

PROCEDURE compileDir:
    DEFINE INPUT PARAMETER pcDir AS CHARACTER NO-UNDO.

    DEFINE VARIABLE cFile     AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cFullPath AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cAttr     AS CHARACTER NO-UNDO.
    DEFINE VARIABLE cExt      AS CHARACTER NO-UNDO.

    INPUT FROM OS-DIR(pcDir).
    REPEAT:
        IMPORT cFile cFullPath cAttr.

        IF LOOKUP(cFile, ".,..":u) > 0 THEN NEXT.

        IF cAttr MATCHES "*D*":u THEN
            RUN compileDir(cFullPath).
        ELSE IF cAttr MATCHES "*F*":u THEN
        DO:
            cExt = IF NUM-ENTRIES(cFile, ".":u) > 1
                   THEN ENTRY(NUM-ENTRIES(cFile, ".":u), cFile, ".":u)
                   ELSE "".

            IF LOOKUP(cExt, "cls,p,w":u) > 0 THEN
            DO:
                iNumFiles = iNumFiles + 1.
                MESSAGE "Compiling:" cFullPath.

                COMPILE VALUE(cFullPath)
                    SAVE INTO VALUE(cBuildDir)
                    NO-ERROR.

                IF ERROR-STATUS:ERROR OR COMPILER:NUM-MESSAGES > 0 THEN
                DO:
                    iNumErrors = iNumErrors + 1.
                    IF ERROR-STATUS:ERROR THEN
                        MESSAGE "  ERROR compiling" cFullPath ":" ERROR-STATUS:GET-MESSAGE(1).
                    IF COMPILER:NUM-MESSAGES > 0 THEN
                        MESSAGE "  ERROR compiling" cFullPath ":" COMPILER:GET-MESSAGE(COMPILER:NUM-MESSAGES).
                END.
            END.
        END.
    END.
    INPUT CLOSE.
END PROCEDURE.

RUN compileDir(cSrcDir).

MESSAGE SUBSTITUTE("Compiled &1 file(s), &2 error(s).", iNumFiles, iNumErrors).
