/*------------------------------------------------------------------------
    File        : LedAuteurBE.cls
    Purpose     : Business Entity for led_auteur (artikels met
                  auteursrechten - ~536K rows in production). NO-LOCK
                  reads, EXCLUSIVE-LOCK in a transaction for writes.
    Field map   : artnr   -> artnr   (PK, char(50), validated against artikel.artnr)
                  profiel -> profiel (logical)
    Notes       : GetItems pushes the artnr/artnrPrefix filter AND the
                  page window down to the ABL query itself (BEGINS on the
                  unique led_auteur-x1 index, plus skip/limit accounting
                  done inside the single FOR EACH) - it never loads the
                  536K-row table into memory first. Same
                  index-range-scan-with-early-exit pattern as
                  Luna.BusinessLogic.ArtikelBE:GetArtikelen against the
                  ~1.8M-row artikel table.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedAuteurBE:

    DEFINE TEMP-TABLE ttLedAuteur NO-UNDO SERIALIZE-NAME "items":u
        FIELD artnr   AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD profiel AS LOGICAL   SERIALIZE-NAME "profiel":u
        INDEX idx-artnr IS PRIMARY artnr.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_auteur, BUFFER pbTt FOR ttLedAuteur ):
        ASSIGN
            pbTt.artnr   = pbSrc.artnr
            pbTt.profiel = pbSrc.profiel
            .
    END METHOD.

    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_auteur ):
        IF poBody:Has("profiel":u) THEN pbRow.profiel = poBody:GetLogical("profiel":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_auteur rows, filtered by artnr (exact)
                 and/or artnrPrefix (BEGINS). Both the filter and the
                 page/skip window are applied directly by this single FOR
                 EACH (range-scanning the unique led_auteur-x1 index on
                 artnr) - this table has ~536K rows in production and must
                 never be pulled fully into memory first.
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to
                 already be validated/clamped by the caller.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage         AS INTEGER,
        INPUT  piPageSize      AS INTEGER,
        INPUT  pcArtnr         AS CHARACTER,
        INPUT  pcArtnrPrefix   AS CHARACTER,
        OUTPUT plHasMore       AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER   NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER   NO-UNDO.
        DEFINE VARIABLE cScan  AS CHARACTER NO-UNDO.

        EMPTY TEMP-TABLE ttLedAuteur.

        ASSIGN
            pcArtnr       = TRIM(pcArtnr)
            pcArtnrPrefix = TRIM(pcArtnrPrefix)
            cScan         = (IF pcArtnr NE "":u THEN pcArtnr ELSE pcArtnrPrefix)
            iSkip         = (piPage - 1) * piPageSize
            iSeen         = 0
            iTaken        = 0
            plHasMore     = FALSE
            .

        /* artnr BEGINS cScan is a single, un-OR'd condition so the query
           optimizer can range-scan the unique led_auteur-x1 index - see
           Luna.BusinessLogic.ArtikelBE:GetArtikelen for why this must stay
           un-OR'd. "x BEGINS ''" is always TRUE, so this is a no-op filter
           when cScan is blank. The exact-artnr case is narrowed further by
           the per-row NE check below (BEGINS alone would also match longer
           artnrs sharing the same prefix). */
        FOR EACH led_auteur NO-LOCK WHERE led_auteur.artnr BEGINS cScan BY led_auteur.artnr:

            IF pcArtnr NE "":u AND led_auteur.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedAuteur.
            CopyToTt( BUFFER led_auteur, BUFFER ttLedAuteur ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedAuteur:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcArtnr AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedAuteur.

        FIND FIRST led_auteur NO-LOCK WHERE led_auteur.artnr EQ pcArtnr NO-ERROR.

        IF AVAILABLE led_auteur THEN
        DO:
            CREATE ttLedAuteur.
            CopyToTt( BUFFER led_auteur, BUFFER ttLedAuteur ).
        END.

        RETURN TEMP-TABLE ttLedAuteur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_auteur row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - artnr already has a led_auteur row.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem( INPUT pcArtnr AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedAuteur.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_auteur EXCLUSIVE-LOCK WHERE led_auteur.artnr EQ pcArtnr NO-ERROR.
            IF AVAILABLE led_auteur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_auteur &1 already exists":u, pcArtnr), 409).

            CREATE led_auteur.
            ASSIGN led_auteur.artnr = pcArtnr.
            ApplyFields( INPUT poBody, BUFFER led_auteur ).

            CREATE ttLedAuteur.
            CopyToTt( BUFFER led_auteur, BUFFER ttLedAuteur ).
        END.

        RETURN TEMP-TABLE ttLedAuteur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_auteur row (only profiel is writable).
        Errors : AppError 404 - artnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem( INPUT pcArtnr AS CHARACTER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedAuteur.

        DO TRANSACTION:
            FIND FIRST led_auteur EXCLUSIVE-LOCK WHERE led_auteur.artnr EQ pcArtnr NO-ERROR.
            IF NOT AVAILABLE led_auteur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_auteur &1 not found":u, pcArtnr), 404).

            ApplyFields( INPUT poBody, BUFFER led_auteur ).

            CREATE ttLedAuteur.
            CopyToTt( BUFFER led_auteur, BUFFER ttLedAuteur ).
        END.

        RETURN TEMP-TABLE ttLedAuteur:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcArtnr AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_auteur EXCLUSIVE-LOCK WHERE led_auteur.artnr EQ pcArtnr NO-ERROR.
            IF NOT AVAILABLE led_auteur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("led_auteur &1 not found":u, pcArtnr), 404).

            DELETE led_auteur.
        END.

    END METHOD.

END CLASS. 
