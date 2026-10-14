/*------------------------------------------------------------------------
    File        : RefreshOmzetanalyseDealersCache.p
    Purpose     : Standalone batch entry point that refreshes the
                  Omzetanalyse dealers (DNOM dashboard) cache file on disk
                  (see Luna.BusinessLogic.OmzetanalyseDealersCacheService).
                  Meant to be run every 5 minutes by a Windows Scheduled
                  Task (see RefreshOmzetanalyseDealersCache.ps1 and
                  Luna-RefreshOmzetanalyseDealersCache-task.xml in this
                  folder) - runs as its own ABL client session, completely
                  independent of the PASOE web agents, so the ~20s scan
                  never competes with normal request handling.
    Usage       : _progres -b -p RefreshOmzetanalyseDealersCache.p -param "<buildDir>"
    Notes       : Uses DYNAMIC-NEW/DYNAMIC-INVOKE instead of a statically
                  class-typed variable, because a plain
                  "DEFINE VARIABLE ... AS Luna.BusinessLogic....'" would
                  need <buildDir> on PROPATH already at *compile* time of
                  this .p (before the ASSIGN below ever runs) - _progres
                  on Windows does not pick up a PROPATH environment
                  variable set by the calling script either, so the only
                  way to point PROPATH at Backend/build from the outside
                  is this SESSION:PARAMETER + runtime ASSIGN, same as
                  scripts/compile.p does for its own srcDir/buildDir.
  ----------------------------------------------------------------------*/

DEFINE VARIABLE cBuildDir AS CHARACTER              NO-UNDO.
DEFINE VARIABLE oCache    AS Progress.Lang.Object   NO-UNDO.

ASSIGN
    cBuildDir = SESSION:PARAMETER
    PROPATH   = cBuildDir + ",":u + PROPATH
    .

oCache = DYNAMIC-NEW "Luna.BusinessLogic.OmzetanalyseDealersCacheService":u () NO-ERROR.

IF NOT VALID-OBJECT(oCache) THEN
DO:
    MESSAGE SUBSTITUTE("Failed to instantiate OmzetanalyseDealersCacheService: &1":u,
        (IF ERROR-STATUS:ERROR THEN ERROR-STATUS:GET-MESSAGE(1) ELSE "unknown error":u)).
    QUIT.
END.

DYNAMIC-INVOKE(oCache, "RefreshCache":u).

QUIT.
