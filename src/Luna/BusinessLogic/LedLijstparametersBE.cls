/*------------------------------------------------------------------------
    File        : LedLijstparametersBE.cls
    Purpose     : Business Entity for led_lijstparameters. NO-LOCK reads,
                  EXCLUSIVE-LOCK in a transaction for writes.
    Field map   : categorie -> categorie (PK1, char(40))
                  volgnr    -> volgnr    (PK2, integer)
                  artnr     -> artnr     (PK3, char(50), validated against artikel.artnr)
                  swBegins  -> swBegins  (logical)
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LedLijstparametersBE:

    DEFINE TEMP-TABLE ttLedLijstparameters NO-UNDO SERIALIZE-NAME "items":u
        FIELD categorie AS CHARACTER SERIALIZE-NAME "categorie":u
        FIELD volgnr     AS INTEGER   SERIALIZE-NAME "volgnr":u
        FIELD artnr      AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD swBegins    AS LOGICAL   SERIALIZE-NAME "swBegins":u
        INDEX idx-key IS PRIMARY categorie volgnr artnr.

    METHOD PRIVATE VOID CopyToTt( BUFFER pbSrc FOR led_lijstparameters, BUFFER pbTt FOR ttLedLijstparameters ):
        ASSIGN
            pbTt.categorie = pbSrc.categorie
            pbTt.volgnr    = pbSrc.volgnr
            pbTt.artnr     = pbSrc.artnr
            pbTt.swBegins  = pbSrc.swBegins
            .
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies fields from the JSON body onto a led_lijstparameters
                 buffer. categorie/volgnr/artnr (the key) are never touched
                 here - callers set them once on create; PUT ignores them
                 even if present in the body.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbRow FOR led_lijstparameters ):
        IF poBody:Has("swBegins":u) THEN pbRow.swBegins = poBody:GetLogical("swBegins":u).
    END METHOD.

    METHOD PRIVATE LOGICAL ArtikelExists( INPUT pcArtnr AS CHARACTER ):
        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        RETURN AVAILABLE artikel.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of led_lijstparameters rows, optionally
                 filtered by categorie (exact) and/or artnr (exact).
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already
                 be validated/clamped by the caller. This table is small
                 (lookup/config table), so no scan-depth cap is needed.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetItems(
        INPUT  piPage       AS INTEGER,
        INPUT  piPageSize    AS INTEGER,
        INPUT  pcCategorie   AS CHARACTER,
        INPUT  pcArtnr       AS CHARACTER,
        OUTPUT plHasMore     AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttLedLijstparameters.

        ASSIGN
            pcCategorie = TRIM(pcCategorie)
            pcArtnr     = TRIM(pcArtnr)
            iSkip       = (piPage - 1) * piPageSize
            iSeen       = 0
            iTaken      = 0
            plHasMore   = FALSE
            .

        FOR EACH led_lijstparameters NO-LOCK
            WHERE led_lijstparameters.categorie BEGINS pcCategorie
            BY led_lijstparameters.categorie BY led_lijstparameters.volgnr:

            IF pcArtnr NE "":u AND led_lijstparameters.artnr NE pcArtnr THEN NEXT.

            iSeen = iSeen + 1.
            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttLedLijstparameters.
            CopyToTt( BUFFER led_lijstparameters, BUFFER ttLedLijstparameters ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttLedLijstparameters:HANDLE.

    END METHOD.

    METHOD PUBLIC HANDLE GetItem( INPUT pcCategorie AS CHARACTER, INPUT piVolgnr AS INTEGER, INPUT pcArtnr AS CHARACTER ):

        EMPTY TEMP-TABLE ttLedLijstparameters.

        FIND FIRST led_lijstparameters NO-LOCK
            WHERE led_lijstparameters.categorie EQ pcCategorie
              AND led_lijstparameters.volgnr    EQ piVolgnr
              AND led_lijstparameters.artnr     EQ pcArtnr
            NO-ERROR.

        IF AVAILABLE led_lijstparameters THEN
        DO:
            CREATE ttLedLijstparameters.
            CopyToTt( BUFFER led_lijstparameters, BUFFER ttLedLijstparameters ).
        END.

        RETURN TEMP-TABLE ttLedLijstparameters:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new led_lijstparameters row.
        Errors : AppError 404 - artnr not found in artikel.
                 AppError 409 - the categorie/volgnr/artnr combo already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateItem(
        INPUT pcCategorie AS CHARACTER, INPUT piVolgnr AS INTEGER, INPUT pcArtnr AS CHARACTER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedLijstparameters.

        IF NOT ArtikelExists(pcArtnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("artikel &1 not found":u, pcArtnr), 404).

        DO TRANSACTION:
            FIND FIRST led_lijstparameters EXCLUSIVE-LOCK
                WHERE led_lijstparameters.categorie EQ pcCategorie
                  AND led_lijstparameters.volgnr    EQ piVolgnr
                  AND led_lijstparameters.artnr     EQ pcArtnr
                NO-ERROR.
            IF AVAILABLE led_lijstparameters THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_lijstparameters &1/&2/&3 already exists":u, pcCategorie, piVolgnr, pcArtnr), 409).

            CREATE led_lijstparameters.
            ASSIGN
                led_lijstparameters.categorie = pcCategorie
                led_lijstparameters.volgnr    = piVolgnr
                led_lijstparameters.artnr     = pcArtnr
                .
            ApplyFields( INPUT poBody, BUFFER led_lijstparameters ).

            CREATE ttLedLijstparameters.
            CopyToTt( BUFFER led_lijstparameters, BUFFER ttLedLijstparameters ).
        END.

        RETURN TEMP-TABLE ttLedLijstparameters:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing led_lijstparameters row (only swBegins
                 is writable - the key is immutable).
        Errors : AppError 404 - row not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateItem(
        INPUT pcCategorie AS CHARACTER, INPUT piVolgnr AS INTEGER, INPUT pcArtnr AS CHARACTER,
        INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttLedLijstparameters.

        DO TRANSACTION:
            FIND FIRST led_lijstparameters EXCLUSIVE-LOCK
                WHERE led_lijstparameters.categorie EQ pcCategorie
                  AND led_lijstparameters.volgnr    EQ piVolgnr
                  AND led_lijstparameters.artnr     EQ pcArtnr
                NO-ERROR.
            IF NOT AVAILABLE led_lijstparameters THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_lijstparameters &1/&2/&3 not found":u, pcCategorie, piVolgnr, pcArtnr), 404).

            ApplyFields( INPUT poBody, BUFFER led_lijstparameters ).

            CREATE ttLedLijstparameters.
            CopyToTt( BUFFER led_lijstparameters, BUFFER ttLedLijstparameters ).
        END.

        RETURN TEMP-TABLE ttLedLijstparameters:HANDLE.

    END METHOD.

    METHOD PUBLIC VOID DeleteItem( INPUT pcCategorie AS CHARACTER, INPUT piVolgnr AS INTEGER, INPUT pcArtnr AS CHARACTER ):

        DO TRANSACTION:
            FIND FIRST led_lijstparameters EXCLUSIVE-LOCK
                WHERE led_lijstparameters.categorie EQ pcCategorie
                  AND led_lijstparameters.volgnr    EQ piVolgnr
                  AND led_lijstparameters.artnr     EQ pcArtnr
                NO-ERROR.
            IF NOT AVAILABLE led_lijstparameters THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("led_lijstparameters &1/&2/&3 not found":u, pcCategorie, piVolgnr, pcArtnr), 404).

            DELETE led_lijstparameters.
        END.

    END METHOD.

END CLASS. 
