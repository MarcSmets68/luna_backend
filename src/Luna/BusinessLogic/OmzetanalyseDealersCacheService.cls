/*------------------------------------------------------------------------
    File        : OmzetanalyseDealersCacheService.cls
    Purpose     : Persists the (expensive, ~20s) Omzetanalyse dealers
                  result for the fixed DNOM dashboard request
                  (soort=DNOM, perDealer, inclusiefZonderOmzet) to a shared
                  cache file on disk, so Luna.Web.RapportageHandler can
                  serve GET /rapportage/omzetanalyse-dealers from that
                  cache instead of recomputing it live on every request.
                  The cache is refreshed every 5 minutes by a Windows
                  Scheduled Task running Backend/scripts/
                  RefreshOmzetanalyseDealersCache.ps1 (see that script and
                  Backend/scripts/Luna-RefreshOmzetanalyseDealersCache-
                  task.xml) - that refresh runs as a standalone ABL batch
                  client, completely independent of the PASOE web agents,
                  so it never competes with normal request handling.
    Notes       : File-based (not a DB table) - no schema change needed,
                  and the cache survives a PASOE/frontend restart. One
                  shared cache file for the one canned request the new
                  dashboard page always makes; every other parameter
                  combination still computes live in RapportageHandler.
                  The file wraps the RAW dataset JSON plus a generatedAt
                  stamp: shaping (ShapeOmzetanalyse) stays in the handler
                  and generatedAt reflects refresh time, not request time.
                  A failed refresh is logged and leaves the existing cache
                  file untouched - callers keep serving the last good
                  snapshot instead of a hard error. As a backstop, a cache
                  file older than iStaleAfterMin (6) minutes is recomputed
                  on read, so the report still refreshes when the scheduled
                  task isn't registered or hasn't run - at the cost of one
                  slow request. InvalidateCache() exists for ops/debug:
                  delete the file and the next GetReport() call recomputes
                  live.
    Syntax      : Called from Luna.Web.RapportageHandler (GET
                  /rapportage/omzetanalyse-dealers when the request
                  matches the canned params) and from Backend/scripts/
                  RefreshOmzetanalyseDealersCache.p (scheduled refresh).
    Author(s)   : Devin
    Created     : 2026-10-14
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.OmzetanalyseDealersBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OmzetanalyseDealersCacheService:

    /* Resolved in the constructor from this class's own location on
       PROPATH (see ResolvePaths), so the cache lives under the same
       backend checkout PASOE/the batch client actually runs from -
       regardless of where that checkout sits on disk. */
    DEFINE PRIVATE VARIABLE cCacheDir  AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cCacheFile AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cTmpFile   AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cLogFile   AS CHARACTER NO-UNDO.

    /* Cache older than this is recomputed on read - just past the 5-minute
       refresh interval of the scheduled task, so it only kicks in when the
       task isn't running (see CacheIsStale). */
    DEFINE PRIVATE VARIABLE iStaleAfterMin AS INTEGER NO-UNDO INITIAL 6.

    /*------------------------------------------------------------------------------
        Purpose: Locates the backend root and derives the cache file paths.
                 Finds this class's own .r (or .cls) on PROPATH - e.g.
                 <root>\build\Luna\BusinessLogic\OmzetanalyseDealers-
                 CacheService.r - and puts the cache at <root>\cache\.
                 Falls back to the known checkout path only when the class
                 itself can't be located (shouldn't happen - if it can't,
                 the class couldn't have loaded either).
    ------------------------------------------------------------------------------*/
    CONSTRUCTOR PUBLIC OmzetanalyseDealersCacheService():

        DEFINE VARIABLE cSelf AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRoot AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.

        cSelf = SEARCH("Luna/BusinessLogic/OmzetanalyseDealersCacheService.r":u).
        IF cSelf EQ ? THEN
            cSelf = SEARCH("Luna/BusinessLogic/OmzetanalyseDealersCacheService.cls":u).

        IF cSelf NE ? THEN
        DO:
            iIdx = MAX(R-INDEX(cSelf, "\build\":u),
                       R-INDEX(cSelf, "\src\":u)).
            IF iIdx GT 1 THEN
                cRoot = SUBSTRING(cSelf, 1, iIdx - 1).
        END.

        IF cRoot EQ ? OR cRoot EQ "":u THEN
            cRoot = "C:\LunaWEB - Workspace\luna_backend":u.

        ASSIGN
            cCacheDir  = cRoot + "\cache\":u
            cCacheFile = cCacheDir + "omzetanalyse-dealers-dnom.json":u
            cTmpFile   = cCacheDir + "omzetanalyse-dealers-dnom.json.tmp":u
            cLogFile   = cCacheDir + "omzetanalyse-dealers-refresh.log":u
            .

    END CONSTRUCTOR.

    /*------------------------------------------------------------------------------
        Purpose: Returns the current DNOM dashboard report - from the cache
                 file if one exists and is fresh, otherwise (first call
                 after a fresh deploy, a missing scheduled task, or a cache
                 older than iStaleAfterMin) by recomputing it live and
                 writing a fresh cache file so every subsequent call is
                 fast again. Never throws to the caller on cache READ
                 problems - a corrupt/unreadable cache file falls back to a
                 live recompute. RefreshCache() itself may still throw
                 (same as a live request would).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetReport():

        IF CacheFileExists() AND NOT CacheIsStale() THEN
        DO ON ERROR UNDO, THROW:
            RETURN ReadCache().

            CATCH oError AS Progress.Lang.Error:
                LogError(SUBSTITUTE("ReadCache failed, falling back to live recompute: &1":u, oError:GetMessage(1))).
            END CATCH.
        END.

        RETURN RefreshCache().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Whether the cache file is older than iStaleAfterMin minutes.
                 The scheduled task refreshes every 5 minutes, so a fresh
                 cache never trips this; it exists purely as a self-healing
                 backstop for environments where the task isn't registered
                 or hasn't run (one slow request rewrites the file).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL CacheIsStale():

        DEFINE VARIABLE dtzModified AS DATETIME-TZ NO-UNDO.

        FILE-INFO:FILE-NAME = cCacheFile.
        IF FILE-INFO:FULL-PATHNAME EQ ? THEN
            RETURN TRUE.

        /* FILE-MOD-* are naive local values; NOW is DATETIME-TZ, so the
           mtime must be built as DATETIME-TZ too - a naive DATETIME is
           read as UTC, which shifts it by the local offset and silently
           makes the file look eternally fresh. */
        dtzModified = DATETIME-TZ(FILE-INFO:FILE-MOD-DATE,
                                  FILE-INFO:FILE-MOD-TIME * 1000).

        RETURN NOW - dtzModified GT iStaleAfterMin * 60000.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Whether the cache file currently exists on disk.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC LOGICAL CacheFileExists():
        RETURN SEARCH(cCacheFile) NE ?.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes the cache file (if any) so the next GetReport()
                 call recomputes live instead of serving stale data.
                 Best-effort: logs (does not throw) on failure - a failed
                 invalidation just means the report stays stale a bit
                 longer, it must never break the request that triggered it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID InvalidateCache():

        IF SEARCH(cCacheFile) NE ? THEN
            OS-DELETE VALUE(cCacheFile).

        CATCH oError AS Progress.Lang.Error:
            LogError(SUBSTITUTE("Failed to invalidate cache file: &1":u, oError:GetMessage(1))).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reads and parses the existing cache file. Throws if it's
                 missing, unreadable or not valid JSON - callers should
                 either check CacheFileExists() first or catch and fall
                 back to RefreshCache(), as GetReport() does.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject ReadCache():

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        /* The file is always written as UTF-8 by WriteCacheFile() below -
           force that same codepage on both ends of the read back (see
           LakproductieCacheService for why both SOURCE and TARGET are
           required). */
        COPY-LOB FROM FILE cCacheFile TO lcJson
            CONVERT SOURCE CODEPAGE "UTF-8":u TARGET CODEPAGE "UTF-8":u.

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Recomputes the canned DNOM dashboard report live (the same
                 call RapportageHandler makes for a live request) and
                 persists it to the cache file. Called every 5 minutes by
                 the scheduled task (RefreshOmzetanalyseDealersCache.p), and
                 once inline by GetReport() as a cold-start fallback.
                 Always returns the freshly computed result, even if
                 persisting it to disk fails - that failure is logged, not
                 thrown, so a request never fails just because the disk
                 write did.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject RefreshCache():

        DEFINE VARIABLE oService AS OmzetanalyseDealersBE NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE              NO-UNDO.
        DEFINE VARIABLE lcJson   AS LONGCHAR            NO-UNDO.
        DEFINE VARIABLE lcWrap   AS LONGCHAR            NO-UNDO.
        DEFINE VARIABLE oParser  AS ObjectModelParser   NO-UNDO.
        DEFINE VARIABLE oWrap    AS JsonObject          NO-UNDO.

        /* The one canned request the dashboard page always makes:
           JAREN mode, soort DNOM, per dealer, no empty rows, seeded
           zero-omzet dealers included. */
        oService = NEW OmzetanalyseDealersBE().
        hResult  = oService:GetAnalyse(?, ?, ?, "DNOM":u, TRUE, FALSE, TRUE).

        hResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).
        oParser = NEW ObjectModelParser().

        oWrap = NEW JsonObject().
        oWrap:Add("generatedAt":u, ISO-DATE(NOW)).
        oWrap:Add("data":u, CAST(oParser:Parse(lcJson), JsonObject)).

        lcJson = ?.
        oWrap:Write(lcWrap, TRUE).

        WriteCacheFile(lcWrap).

        RETURN oWrap.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes pcJson to the cache file, atomically from the
                 point of view of a concurrent reader: first to a .tmp
                 file, then OS-RENAME'd over the real cache file, so
                 ReadCache() never observes a partially written file.
                 Logs (does not throw) on any failure, leaving whatever
                 cache file already existed untouched.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteCacheFile( INPUT pcJson AS LONGCHAR ):

        EnsureCacheDir().

        /* Always write as UTF-8, regardless of which session's default
           codepage is doing the writing (the scheduled-refresh batch
           client and the PASOE web agent aren't guaranteed to match) -
           ReadCache() converts back from this same fixed codepage. */
        COPY-LOB pcJson TO FILE cTmpFile CONVERT TARGET CODEPAGE "UTF-8":u.

        IF SEARCH(cCacheFile) NE ? THEN
            OS-DELETE VALUE(cCacheFile).

        OS-RENAME VALUE(cTmpFile) VALUE(cCacheFile).

        CATCH oError AS Progress.Lang.Error:
            LogError(SUBSTITUTE("Failed to write cache file: &1":u, oError:GetMessage(1))).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates the cache directory if it doesn't exist yet.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureCacheDir():

        FILE-INFO:FILE-NAME = cCacheDir.
        IF FILE-INFO:FULL-PATHNAME EQ ? THEN
            OS-CREATE-DIR VALUE(cCacheDir).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Appends a timestamped line to the refresh log - the only
                 place refresh/write failures surface, since a failed
                 refresh must never break a request (the stale cache keeps
                 serving instead).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID LogError( INPUT pcMessage AS CHARACTER ):

        DEFINE VARIABLE lOpened AS LOGICAL NO-UNDO INITIAL FALSE.

        DO ON ERROR UNDO, LEAVE:
            EnsureCacheDir().

            OUTPUT TO VALUE(cLogFile) APPEND.
            lOpened = TRUE.
            PUT UNFORMATTED
                SUBSTITUTE("[&1] &2":u, ISO-DATE(NOW), pcMessage) SKIP.

            CATCH oError AS Progress.Lang.Error:
                /* swallow - logging must never break a request */
            END CATCH.

            FINALLY:
                IF lOpened THEN
                    OUTPUT CLOSE.
            END FINALLY.
        END.

    END METHOD.

END CLASS.
