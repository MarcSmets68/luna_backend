/*------------------------------------------------------------------------
    File        : LoginThrottle.cls
    Purpose     : Brute-force protection for AuthBE:Login - after
                  iMaxFailures failed attempts for the same gebruikerskode
                  within iWindowSecs the login is refused (429) until the
                  oldest counted failure falls out of the window.
    Storage     : One small append-only text file per kode under
                  <backend root>\cache\login-attempts\ (cache/ is
                  gitignored), named after the SHA-256 of the upper-cased
                  kode. One epoch-seconds timestamp per line = one failed attempt.
                  Chosen because (a) the schema/shared database must not be
                  changed, (b) the file is shared by every PASOE agent
                  session and survives a restart (an in-memory counter
                  would be per agent and reset on restart), (c) appending
                  one line is far more robust against concurrent requests
                  than read-modify-write of a counter, and (d) the
                  project already uses cache/ files the same way (see
                  LakproductieCacheService). The hash keeps user input out
                  of the file name.
    Description : Failures are counted per kode WHETHER OR NOT the kode
                  exists, so the 429 does not reveal if a kode is valid.
                  The check happens before the password is verified, so a
                  locked kode answers 429 even with the correct password.
                  Stale files are removed when seen and by a sweep on every
                  recorded failure, so random kodes cannot fill the disk.
                  Any I/O problem fails OPEN (login keeps working) - the
                  throttle must never lock everybody out.
    Author(s)   : Devin
    Created     : 2026-10-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LoginThrottle:

    DEFINE PRIVATE VARIABLE iMaxFailures AS INTEGER   NO-UNDO INITIAL 5.
    DEFINE PRIVATE VARIABLE iWindowSecs  AS INTEGER   NO-UNDO INITIAL 900.
    DEFINE PRIVATE VARIABLE cDir         AS CHARACTER NO-UNDO.

    CONSTRUCTOR PUBLIC LoginThrottle():

        DEFINE VARIABLE cSelf AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRoot AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.

        cSelf = SEARCH("Luna/BusinessLogic/LoginThrottle.r":u).
        IF cSelf EQ ? THEN
            cSelf = SEARCH("Luna/BusinessLogic/LoginThrottle.cls":u).

        IF cSelf NE ? THEN
        DO:
            iIdx = MAX(R-INDEX(cSelf, "\build\":u),
                       R-INDEX(cSelf, "\src\":u)).
            IF iIdx GT 1 THEN
                cRoot = SUBSTRING(cSelf, 1, iIdx - 1).
        END.

        IF cRoot EQ ? OR cRoot EQ "":u THEN
            cRoot = "C:\LunaWEB - Workspace\luna_backend":u.

        cDir = cRoot + "\cache\login-attempts\":u.

    END CONSTRUCTOR.

    /* Test hook: lets a test run use its own limits. */
    CONSTRUCTOR PUBLIC LoginThrottle( INPUT piMaxFailures AS INTEGER, INPUT piWindowSecs AS INTEGER ):

        THIS-OBJECT().
        ASSIGN
            iMaxFailures = piMaxFailures
            iWindowSecs  = piWindowSecs
            .

    END CONSTRUCTOR.

    METHOD PRIVATE CHARACTER GetFileName( INPUT pcKode AS CHARACTER ):

        DEFINE VARIABLE cKey    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE rDigest AS RAW       NO-UNDO.
        DEFINE VARIABLE cHex    AS CHARACTER NO-UNDO.

        cKey    = UPPER(SUBSTRING(TRIM(pcKode), 1, 200)).
        rDigest = MESSAGE-DIGEST("SHA-256":u, cKey).
        cHex    = STRING(HEX-ENCODE(rDigest)).

        RETURN cDir + cHex + ".log":u.

    END METHOD.

    /* Seconds since 1970-01-01 UTC (timezone/DST independent). One line in
       the attempts file = one of these numbers. */
    METHOD PRIVATE INT64 GetEpochSecs():

        RETURN INT64(INTERVAL(NOW, DATETIME-TZ(1, 1, 1970, 0, 0, 0, 0, 0), "seconds":u)).

    END METHOD.

    /* Returns 0 when the kode may try to log in, otherwise the number of
       whole minutes (at least 1) until it may try again. */
    METHOD PUBLIC INTEGER GetLockoutMinutes( INPUT pcKode AS CHARACTER ):

        DEFINE VARIABLE cFile     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cLine     AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iEntry    AS INT64       NO-UNDO.
        DEFINE VARIABLE iNow      AS INT64       NO-UNDO.
        DEFINE VARIABLE iAge      AS INT64       NO-UNDO.
        DEFINE VARIABLE iCount    AS INTEGER     NO-UNDO INITIAL 0.
        DEFINE VARIABLE iMaxAge   AS INT64       NO-UNDO INITIAL -1.
        DEFINE VARIABLE iWait     AS INT64       NO-UNDO.

        cFile = GetFileName(pcKode).

        FILE-INFO:FILE-NAME = cFile.
        IF FILE-INFO:FULL-PATHNAME EQ ? THEN
            RETURN 0.

        iNow = GetEpochSecs().

        INPUT FROM VALUE(cFile).
        REPEAT ON ENDKEY UNDO, LEAVE:
            IMPORT UNFORMATTED cLine.
            iEntry = INT64(TRIM(cLine)) NO-ERROR.
            IF ERROR-STATUS:ERROR OR iEntry EQ ? THEN
                NEXT.
            iAge = iNow - iEntry.
            IF iAge LT iWindowSecs THEN
                ASSIGN
                    iCount  = iCount + 1
                    iMaxAge = MAX(iMaxAge, iAge)
                    .
        END.
        INPUT CLOSE.

        IF iCount EQ 0 THEN
        DO:
            OS-DELETE VALUE(cFile).
            RETURN 0.
        END.

        IF iCount LT iMaxFailures THEN
            RETURN 0.

        /* iMaxAge = age of the OLDEST failure still inside the window. */
        iWait = iWindowSecs - iMaxAge.
        RETURN INTEGER(MAX(1, TRUNCATE((iWait + 59) / 60, 0))).

        CATCH oError AS Progress.Lang.Error:
            /* Fail open. */
            INPUT CLOSE.
            RETURN 0.
        END CATCH.

    END METHOD.

    /* Records one failed attempt for the kode (whether it exists or not). */
    METHOD PUBLIC VOID RecordFailure( INPUT pcKode AS CHARACTER ):

        DEFINE VARIABLE cTrim AS CHARACTER NO-UNDO.

        cTrim = RIGHT-TRIM(cDir, "\":u).
        OS-CREATE-DIR VALUE(SUBSTRING(cTrim, 1, R-INDEX(cTrim, "\":u) - 1)).
        OS-CREATE-DIR VALUE(cTrim).

        OUTPUT TO VALUE(GetFileName(pcKode)) APPEND.
        PUT UNFORMATTED GetEpochSecs() SKIP.
        OUTPUT CLOSE.

        SweepStaleFiles().

        CATCH oError AS Progress.Lang.Error:
            /* Fail open. */
            OUTPUT CLOSE.
        END CATCH.

    END METHOD.

    /* A successful login clears the kode's failure history. */
    METHOD PUBLIC VOID Reset( INPUT pcKode AS CHARACTER ):

        OS-DELETE VALUE(GetFileName(pcKode)).

        CATCH oError AS Progress.Lang.Error:
            /* Fail open. */
        END CATCH.

    END METHOD.

    /* Deletes files whose last failure is older than the window. */
    METHOD PRIVATE VOID SweepStaleFiles():

        DEFINE VARIABLE cName AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cFull AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cAttr AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iAge  AS INT64     NO-UNDO.

        INPUT FROM OS-DIR(RIGHT-TRIM(cDir, "\":u)).
        REPEAT:
            IMPORT cName cFull cAttr.
            IF NOT cName MATCHES "*.log":u THEN
                NEXT.
            FILE-INFO:FILE-NAME = cFull.
            IF FILE-INFO:FILE-MOD-DATE EQ ? THEN
                NEXT.
            iAge = (TODAY - FILE-INFO:FILE-MOD-DATE) * 86400
                 + (TIME - FILE-INFO:FILE-MOD-TIME).
            IF iAge GT iWindowSecs THEN
                OS-DELETE VALUE(cFull).
        END.
        INPUT CLOSE.

        CATCH oError AS Progress.Lang.Error:
            /* Best effort only. */
        END CATCH.

    END METHOD.

END CLASS.
