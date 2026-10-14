/*------------------------------------------------------------------------
    File        : LakproductieCacheService.cls
    Purpose     : Persists the (expensive, up to ~1 minute) Lakproduktie
                  overview result to a single shared cache file on disk,
                  so Luna.Web.LakproductieHandler can serve
                  GET /lakproduktie from that cache instead of
                  recomputing it live on every request.
                  The cache is refreshed every 5 minutes by a Windows
                  Scheduled Task running Backend/scripts/
                  RefreshLakproductieCache.ps1 (see that script,
                  Backend/scripts/Luna-RefreshLakproductieCache-task.xml
                  and Backend/README.md, "Lakproduktie-cache" section) -
                  that refresh runs as a standalone ABL batch client,
                  completely independent of the PASOE web agents, so it
                  never competes with normal request handling.
    Notes       : File-based (not a DB table) - no schema change needed,
                  and the cache survives a PASOE/frontend restart (unlike
                  an in-memory cache would). One shared cache file for
                  every user - GET /lakproduktie returns the same data
                  for everyone today (no user-specific filtering server-
                  side), so there's no need for a per-user/per-session
                  cache.
                  A failed refresh (e.g. DB unreachable) is logged to
                  cLogFile and leaves the existing cache file untouched -
                  callers keep serving the last good snapshot instead of
                  a hard error. Data can therefore be up to ~5 (or, if a
                  scheduled refresh fails, longer) minutes stale - an
                  accepted tradeoff for this feature.
                  InvalidateCache() lets a write path (today: creating a
                  Lakproduktie bestelling, which bumps bonlijn/
                  bonlijn_productie.besteld directly in the DB) force the
                  next GetItems() call to recompute live instead of waiting
                  for the next scheduled refresh, so a just-ordered line
                  doesn't keep showing as still open for up to 5 minutes.
    Syntax      : Called from Luna.Web.LakproductieHandler (GET
                  /lakproduktie, and InvalidateCache() after POST
                  /lakproduktie/bestelling) and from Backend/scripts/
                  RefreshLakproductieCache.p (the scheduled refresh).
    Author(s)   : Devin
    Created     : 2026-08-19
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LakproductieBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LakproductieCacheService:

    /* Resolved in the constructor from this class's own location on
       PROPATH, so the cache follows whichever backend checkout PASOE and
       the batch refresh actually run from. */
    DEFINE PRIVATE VARIABLE cCacheDir  AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cCacheFile AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cTmpFile   AS CHARACTER NO-UNDO.
    DEFINE PRIVATE VARIABLE cLogFile   AS CHARACTER NO-UNDO.

    CONSTRUCTOR PUBLIC LakproductieCacheService():

        DEFINE VARIABLE cSelf AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRoot AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iIdx  AS INTEGER   NO-UNDO.

        cSelf = SEARCH("Luna/BusinessLogic/LakproductieCacheService.r":u).
        IF cSelf EQ ? THEN
            cSelf = SEARCH("Luna/BusinessLogic/LakproductieCacheService.cls":u).

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
            cCacheFile = cCacheDir + "lakproductie-cache.json":u
            cTmpFile   = cCacheDir + "lakproductie-cache.json.tmp":u
            cLogFile   = cCacheDir + "lakproductie-cache-refresh.log":u
            .

    END CONSTRUCTOR.

    /*------------------------------------------------------------------------------
        Purpose: Returns the current Lakproduktie overview - from the
                 cache file if one exists, otherwise (first call after a
                 fresh deploy / before the first scheduled refresh has
                 run) by recomputing it live and writing a fresh cache
                 file so every subsequent call is fast until the next
                 scheduled refresh. Never throws to the caller - a
                 corrupt/unreadable cache file also falls back to a live
                 recompute.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject GetItems():

        IF CacheFileExists() THEN
        DO ON ERROR UNDO, THROW:
            RETURN ReadCache().

            CATCH oError AS Progress.Lang.Error:
                LogError(SUBSTITUTE("ReadCache failed, falling back to live recompute: &1":u, oError:GetMessage(1))).
            END CATCH.
        END.

        RETURN RefreshCache().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Whether the cache file currently exists on disk.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC LOGICAL CacheFileExists():
        RETURN SEARCH(cCacheFile) NE ?.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes the cache file (if any) so the next GetItems() call
                 falls back to a live recompute instead of serving up to
                 ~5-minute-stale data. Called by Luna.Web.LakproductieHandler
                 right after a Lakproduktie bestelling is created, since that
                 bumps bonlijn/bonlijn_productie.besteld directly in the DB -
                 without this, the overview would keep showing the
                 just-ordered line as still open until the next scheduled
                 refresh. Best-effort: logs (does not throw) on failure, same
                 as WriteCacheFile() - a failed invalidation just means the
                 overview stays stale a bit longer, it must never break the
                 request that triggered it.
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
                 back to RefreshCache(), as GetItems() does.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject ReadCache():

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        /* The file is always written as UTF-8 by WriteCacheFile() below -
           force that same codepage on both ends of the read back. SOURCE
           CODEPAGE alone isn't enough: without an explicit TARGET
           CODEPAGE too, COPY-LOB converts the result into this session's
           -cpinternal (which doesn't have to be UTF-8, and isn't
           guaranteed to match whichever session wrote the file - e.g.
           the scheduled-refresh batch client vs. a PASOE web agent) and
           tags lcJson with THAT codepage - ObjectModelParser:Parse() then
           refuses to auto-detect a JSON encoding from a non-UTF
           codepage. */
        COPY-LOB FROM FILE cCacheFile TO lcJson
            CONVERT SOURCE CODEPAGE "UTF-8":u TARGET CODEPAGE "UTF-8":u.

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Recomputes the Lakproduktie overview live (the same call
                 the WebHandler used to make on every request before this
                 cache existed) and persists it to the cache file. Called
                 every 5 minutes by the scheduled task
                 (RefreshLakproductieCache.p), and once inline by
                 GetItems() as a cold-start fallback. Always returns the
                 freshly computed result, even if persisting it to disk
                 fails - that failure is logged, not thrown, so a request
                 never fails just because the disk write did.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC JsonObject RefreshCache():

        DEFINE VARIABLE oService AS LakproductieBE     NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE              NO-UNDO.
        DEFINE VARIABLE lcJson   AS LONGCHAR             NO-UNDO.
        DEFINE VARIABLE oParser  AS ObjectModelParser    NO-UNDO.
        DEFINE VARIABLE oJson    AS JsonObject           NO-UNDO.

        oService = NEW LakproductieBE().
        hResult  = oService:GetOpenLakproductieItems().

        hResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().
        oJson   = CAST(oParser:Parse(lcJson), JsonObject).

        WriteCacheFile(lcJson).

        RETURN oJson.

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
                 refresh must never break a request (the stale cache
                 keeps serving instead).
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
