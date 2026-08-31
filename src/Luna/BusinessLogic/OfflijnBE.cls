/*------------------------------------------------------------------------
    File        : OfflijnBE.cls
    Purpose     : Business Entity for the "offlijn" (quote line) table -
                  owns full CRUD access for a curated core subset of fields
                  (identification, article, quantities, pricing, status).
                  `offlijn` is a child of `offerte` (linked via offnr+versie)
                  - every method here always operates within the scope of a
                  single offnr+versie. The `offlijn` table has ~60 fields in
                  total; only the subset below is exposed via the API for
                  now.
    Field map (JSON key -> offlijn column):
                  offnr                -> offnr           (PK, immutable, from parent offerte)
                  versie               -> versie           (PK, immutable, from parent offerte)
                  lijnnr               -> lijnnr            (PK, required on create, immutable)
                  groepnr              -> groepnr
                  subgroepnr           -> subgroepnr
                  artnr                -> artnr
                  omschrijving         -> omschr
                  omschrijvingOfferte  -> omschr-off
                  aantal               -> aantal
                  teLeveren            -> te-leveren
                  verkoopprijs         -> vprijs
                  brutoVerkoopprijs    -> bprijs
                  korting              -> korting
                  btwKode              -> btw-kode
                  bedrag               -> bedrag
                  bruto                -> bruto
                  aankoopprijs         -> aprijs
                  opm                  -> opm
                  bestellen            -> bestellen
                  blokkeren            -> blokkeren
                  subtotaal            -> subtotaal
                  kolomtitel           -> kolomtitel
                  infolijn             -> infolijn
    Syntax      : Called from Luna.Web.OfferteHandler (GET/POST/PUT/DELETE
                  /web/offerte/{offnr}/{versie}/lijn and
                  /web/offerte/{offnr}/{versie}/lijn/{lijnnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers are
                  expected to have already validated that the parent offerte
                  (offnr+versie) exists - see EnsureOfferteExists.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OfflijnBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttOfflijn NO-UNDO SERIALIZE-NAME "items":u
        FIELD offnr               AS INTEGER   SERIALIZE-NAME "offnr":u
        FIELD versie              AS INTEGER   SERIALIZE-NAME "versie":u
        FIELD lijnnr              AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD groepnr             AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD subgroepnr          AS INTEGER   SERIALIZE-NAME "subgroepnr":u
        FIELD artnr               AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving        AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD omschrijvingOfferte AS CHARACTER SERIALIZE-NAME "omschrijvingOfferte":u
        FIELD aantal              AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD teLeveren           AS DECIMAL   SERIALIZE-NAME "teLeveren":u
        FIELD verkoopprijs        AS DECIMAL   SERIALIZE-NAME "verkoopprijs":u
        FIELD brutoVerkoopprijs   AS DECIMAL   SERIALIZE-NAME "brutoVerkoopprijs":u
        FIELD korting             AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD btwKode             AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag              AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD bruto               AS DECIMAL   SERIALIZE-NAME "bruto":u
        FIELD aankoopprijs        AS DECIMAL   SERIALIZE-NAME "aankoopprijs":u
        FIELD opm                 AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD bestellen           AS LOGICAL   SERIALIZE-NAME "bestellen":u
        FIELD blokkeren           AS LOGICAL   SERIALIZE-NAME "blokkeren":u
        FIELD subtotaal           AS LOGICAL   SERIALIZE-NAME "subtotaal":u
        FIELD kolomtitel          AS LOGICAL   SERIALIZE-NAME "kolomtitel":u
        FIELD infolijn            AS LOGICAL   SERIALIZE-NAME "infolijn":u
        INDEX idx-lijnnr IS PRIMARY offnr versie lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent offerte (offnr+versie)
                 doesn't exist. Called at the start of every method here so
                 offlijn CRUD never silently operates on/under a
                 non-existent quote.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureOfferteExists( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        FIND FIRST offerte NO-LOCK
            WHERE offerte.offnr EQ piOffnr
              AND offerte.versie EQ piVersie NO-ERROR.

        IF NOT AVAILABLE offerte THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Offerte &1/&2 not found":u, piOffnr, piVersie), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from an `offlijn` buffer
                 into a ttOfflijn row, for use by every read/write method
                 below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbOfflijn FOR offlijn, BUFFER pbTt FOR ttOfflijn ):

        ASSIGN
            pbTt.offnr               = pbOfflijn.offnr
            pbTt.versie              = pbOfflijn.versie
            pbTt.lijnnr              = pbOfflijn.lijnnr
            pbTt.groepnr             = pbOfflijn.groepnr
            pbTt.subgroepnr          = pbOfflijn.subgroepnr
            pbTt.artnr               = pbOfflijn.artnr
            pbTt.omschrijving        = pbOfflijn.omschr
            pbTt.omschrijvingOfferte = pbOfflijn.omschr-off
            pbTt.aantal              = pbOfflijn.aantal
            pbTt.teLeveren           = pbOfflijn.te-leveren
            pbTt.verkoopprijs        = pbOfflijn.vprijs
            pbTt.brutoVerkoopprijs   = pbOfflijn.bprijs
            pbTt.korting             = pbOfflijn.korting
            pbTt.btwKode             = pbOfflijn.btw-kode
            pbTt.bedrag              = pbOfflijn.bedrag
            pbTt.bruto               = pbOfflijn.bruto
            pbTt.aankoopprijs        = pbOfflijn.aprijs
            pbTt.opm                 = pbOfflijn.opm
            pbTt.bestellen           = pbOfflijn.bestellen
            pbTt.blokkeren           = pbOfflijn.blokkeren
            pbTt.subtotaal           = pbOfflijn.subtotaal
            pbTt.kolomtitel          = pbOfflijn.kolomtitel
            pbTt.infolijn            = pbOfflijn.infolijn
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `offlijn` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `offnr`/`versie`/`lijnnr` are never touched here - they are
                 set once on create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbOfflijn FOR offlijn ):

        IF poBody:Has("groepnr":u)             THEN pbOfflijn.groepnr    = poBody:GetInteger("groepnr":u).
        IF poBody:Has("subgroepnr":u)          THEN pbOfflijn.subgroepnr = poBody:GetInteger("subgroepnr":u).
        IF poBody:Has("artnr":u)               THEN pbOfflijn.artnr      = poBody:GetCharacter("artnr":u).
        IF poBody:Has("omschrijving":u)        THEN pbOfflijn.omschr     = poBody:GetCharacter("omschrijving":u).
        IF poBody:Has("omschrijvingOfferte":u) THEN pbOfflijn.omschr-off = poBody:GetCharacter("omschrijvingOfferte":u).
        IF poBody:Has("aantal":u)              THEN pbOfflijn.aantal     = poBody:GetDecimal("aantal":u).
        IF poBody:Has("teLeveren":u)            THEN pbOfflijn.te-leveren = poBody:GetDecimal("teLeveren":u).
        IF poBody:Has("verkoopprijs":u)         THEN pbOfflijn.vprijs     = poBody:GetDecimal("verkoopprijs":u).
        IF poBody:Has("brutoVerkoopprijs":u)    THEN pbOfflijn.bprijs     = poBody:GetDecimal("brutoVerkoopprijs":u).
        IF poBody:Has("korting":u)              THEN pbOfflijn.korting    = poBody:GetDecimal("korting":u).
        IF poBody:Has("btwKode":u)              THEN pbOfflijn.btw-kode   = poBody:GetCharacter("btwKode":u).
        IF poBody:Has("bedrag":u)               THEN pbOfflijn.bedrag     = poBody:GetDecimal("bedrag":u).
        IF poBody:Has("bruto":u)                THEN pbOfflijn.bruto      = poBody:GetDecimal("bruto":u).
        IF poBody:Has("aankoopprijs":u)         THEN pbOfflijn.aprijs     = poBody:GetDecimal("aankoopprijs":u).
        IF poBody:Has("opm":u)                  THEN pbOfflijn.opm        = poBody:GetCharacter("opm":u).
        IF poBody:Has("bestellen":u)            THEN pbOfflijn.bestellen  = poBody:GetLogical("bestellen":u).
        IF poBody:Has("blokkeren":u)             THEN pbOfflijn.blokkeren  = poBody:GetLogical("blokkeren":u).
        IF poBody:Has("subtotaal":u)             THEN pbOfflijn.subtotaal  = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u)            THEN pbOfflijn.kolomtitel = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)              THEN pbOfflijn.infolijn   = poBody:GetLogical("infolijn":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every offlijn row for the given offnr+versie,
                 ordered by lijnnr.
        Notes  : NO-LOCK read-only. Uses the offlijn-x1 (unique) index.
        Errors : AppError code 404 - the parent offnr/versie doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOfflijnen( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        EnsureOfferteExists( piOffnr, piVersie ).

        EMPTY TEMP-TABLE ttOfflijn.

        FOR EACH offlijn NO-LOCK
            WHERE offlijn.offnr EQ piOffnr
              AND offlijn.versie EQ piVersie
            BY offlijn.lijnnr:

            CREATE ttOfflijn.
            CopyToTt( BUFFER offlijn, BUFFER ttOfflijn ).
        END.

        RETURN TEMP-TABLE ttOfflijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single offlijn by offnr+versie+lijnnr, or an
                 empty ttOfflijn if it doesn't exist (the WebHandler turns
                 that into a 404).
        Errors : AppError code 404 - the parent offnr/versie doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOfflijn( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureOfferteExists( piOffnr, piVersie ).

        EMPTY TEMP-TABLE ttOfflijn.

        FIND FIRST offlijn NO-LOCK
            WHERE offlijn.offnr EQ piOffnr
              AND offlijn.versie EQ piVersie
              AND offlijn.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE offlijn THEN
        DO:
            CREATE ttOfflijn.
            CopyToTt( BUFFER offlijn, BUFFER ttOfflijn ).
        END.

        RETURN TEMP-TABLE ttOfflijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns TRUE if more than one of subtotaal/kolomtitel/
                 infolijn is TRUE - these three flags are mutually exclusive,
                 a line can be at most one of them.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL HasConflictingFlags(
        INPUT plSubtotaal  AS LOGICAL,
        INPUT plKolomtitel AS LOGICAL,
        INPUT plInfolijn   AS LOGICAL ):

        DEFINE VARIABLE iCount AS INTEGER NO-UNDO.

        IF plSubtotaal  THEN iCount = iCount + 1.
        IF plKolomtitel THEN iCount = iCount + 1.
        IF plInfolijn   THEN iCount = iCount + 1.

        RETURN iCount GT 1.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new offlijn under the given offnr+versie.
                 - If `lijnnr` is omitted from the body: auto-allocated as
                   MAX(lijnnr for this offnr+versie, default 0) + 10.
                 - If `lijnnr` is provided: today's explicit path - must be a
                   positive integer and must not already exist for that
                   offnr+versie.
                 Also enforces (regardless of lijnnr mode):
                 - at most one of subtotaal/kolomtitel/infolijn may be TRUE.
                 - a subtotaal line requires at least one existing plain line
                   (subtotaal=FALSE AND kolomtitel=FALSE AND infolijn=FALSE)
                   with a smaller lijnnr for this offerte.
        Errors : AppError code 404 - the parent offnr/versie doesn't exist.
                 AppError code 400 - lijnnr invalid (explicit mode); more than
                 one of subtotaal/kolomtitel/infolijn TRUE; or a subtotaal
                 line requested with no preceding plain line to sum.
                 AppError code 409 - (explicit mode) lijnnr already exists
                 for this offerte.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateOfflijn( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iLijnnr      AS INTEGER NO-UNDO.
        DEFINE VARIABLE lHasLijnnr   AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lSubtotaal   AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lKolomtitel  AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lInfolijn    AS LOGICAL NO-UNDO.

        EnsureOfferteExists( piOffnr, piVersie ).

        EMPTY TEMP-TABLE ttOfflijn.

        lHasLijnnr = poBody:Has("lijnnr":u).

        IF lHasLijnnr THEN
        DO:
            iLijnnr = poBody:GetInteger("lijnnr":u) NO-ERROR.
            IF iLijnnr EQ ? OR iLijnnr LE 0 THEN
                UNDO, THROW NEW Progress.Lang.AppError("lijnnr must be a positive integer":u, 400).
        END.

        IF poBody:Has("subtotaal":u)  THEN lSubtotaal  = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u) THEN lKolomtitel = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)   THEN lInfolijn   = poBody:GetLogical("infolijn":u).

        IF HasConflictingFlags(lSubtotaal, lKolomtitel, lInfolijn) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "A line can be at most one of subtotaal/kolomtitel/infolijn":u, 400).

        DO TRANSACTION:
            IF lHasLijnnr THEN
            DO:
                FIND FIRST offlijn EXCLUSIVE-LOCK
                    WHERE offlijn.offnr EQ piOffnr
                      AND offlijn.versie EQ piVersie
                      AND offlijn.lijnnr EQ iLijnnr NO-ERROR.
                IF AVAILABLE offlijn THEN
                    UNDO, THROW NEW Progress.Lang.AppError(
                        SUBSTITUTE("Offlijn &1/&2/&3 already exists":u, piOffnr, piVersie, iLijnnr), 409).
            END.
            ELSE
            DO:
                FIND LAST offlijn USE-INDEX offlijn-x1 EXCLUSIVE-LOCK
                    WHERE offlijn.offnr EQ piOffnr
                      AND offlijn.versie EQ piVersie NO-ERROR.

                iLijnnr = (IF AVAILABLE offlijn THEN offlijn.lijnnr ELSE 0) + 10.
            END.

            IF lSubtotaal THEN
            DO:
                IF NOT CAN-FIND(FIRST offlijn
                    WHERE offlijn.offnr EQ piOffnr
                      AND offlijn.versie EQ piVersie
                      AND offlijn.lijnnr LT iLijnnr
                      AND offlijn.subtotaal EQ FALSE
                      AND offlijn.kolomtitel EQ FALSE
                      AND offlijn.infolijn EQ FALSE) THEN
                    UNDO, THROW NEW Progress.Lang.AppError(
                        "Cannot create a subtotaal line with no preceding lines to sum":u, 400).
            END.

            CREATE offlijn.
            ASSIGN
                offlijn.offnr  = piOffnr
                offlijn.versie = piVersie
                offlijn.lijnnr = iLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER offlijn ).

            CREATE ttOfflijn.
            CopyToTt( BUFFER offlijn, BUFFER ttOfflijn ).
        END.

        RETURN TEMP-TABLE ttOfflijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing offlijn. Only fields present in the JSON
                 body are changed (partial update); `offnr`/`versie`/`lijnnr`
                 are immutable.
        Notes  : Enforces the same subtotaal/kolomtitel/infolijn mutual-
                 exclusivity guard as CreateOfflijn, but computed against the
                 MERGED pre-update-row + body state, since this is a partial
                 update (e.g. an existing row with kolomtitel=TRUE where the
                 body sets subtotaal=TRUE without explicitly clearing
                 kolomtitel is a conflict).
        Errors : AppError code 404 - the parent offnr/versie doesn't exist,
                 or the lijnnr doesn't exist under it.
                 AppError code 400 - the merged state would leave more than
                 one of subtotaal/kolomtitel/infolijn TRUE.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateOfflijn(
        INPUT piOffnr  AS INTEGER,
        INPUT piVersie AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        EnsureOfferteExists( piOffnr, piVersie ).

        EMPTY TEMP-TABLE ttOfflijn.

        DO TRANSACTION:
            FIND FIRST offlijn EXCLUSIVE-LOCK
                WHERE offlijn.offnr EQ piOffnr
                  AND offlijn.versie EQ piVersie
                  AND offlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE offlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offlijn &1/&2/&3 not found":u, piOffnr, piVersie, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER offlijn ).

            IF HasConflictingFlags(offlijn.subtotaal, offlijn.kolomtitel, offlijn.infolijn) THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    "A line can be at most one of subtotaal/kolomtitel/infolijn":u, 400).

            CREATE ttOfflijn.
            CopyToTt( BUFFER offlijn, BUFFER ttOfflijn ).
        END.

        RETURN TEMP-TABLE ttOfflijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Moves the offlijn at {lijnnr} one position "up" or "down" in
                 lijnnr order among the lines of this offnr+versie, by
                 swapping its lijnnr with its immediate neighbor's ("up" =
                 next-smaller lijnnr, "down" = next-larger lijnnr). Nothing
                 else on either row changes. Uses a temporary negative
                 placeholder lijnnr for one of the two rows mid-swap, within
                 one transaction, to avoid a transient unique-index collision
                 on (offnr, versie, lijnnr).
        Notes  : Guard - whichever of the two lines involved in the swap
                 currently has subtotaal = TRUE, if the swap would DECREASE
                 that line's lijnnr, the move is rejected. This single
                 symmetric check covers both "moving the subtotal line
                 itself up" and "moving a normal line down past/above a
                 subtotal line" (both cases decrease the subtotal's lijnnr).
                 Moving a subtotal line DOWN (increasing its lijnnr) is
                 allowed.
        Errors : AppError code 404 - the parent offnr/versie doesn't exist;
                 the target lijnnr doesn't exist; or there is no neighbor in
                 the requested direction.
                 AppError code 400 - pcDirection is neither "up" nor "down";
                 or the swap would move a subtotaal line's lijnnr down
                 (numerically decrease it).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE ReorderOfflijn(
        INPUT piOffnr     AS INTEGER,
        INPUT piVersie    AS INTEGER,
        INPUT piLijnnr    AS INTEGER,
        INPUT pcDirection AS CHARACTER ):

        DEFINE BUFFER bTarget   FOR offlijn.
        DEFINE BUFFER bNeighbor FOR offlijn.

        DEFINE VARIABLE iTargetLijnnr   AS INTEGER NO-UNDO.
        DEFINE VARIABLE iNeighborLijnnr AS INTEGER NO-UNDO.
        DEFINE VARIABLE lTargetSubtotaal   AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lNeighborSubtotaal AS LOGICAL NO-UNDO.

        EnsureOfferteExists( piOffnr, piVersie ).

        pcDirection = LC(TRIM(pcDirection)).

        IF pcDirection NE "up":u AND pcDirection NE "down":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                'direction must be "up" or "down"':u, 400).

        DO TRANSACTION:
            FIND FIRST bTarget EXCLUSIVE-LOCK
                WHERE bTarget.offnr EQ piOffnr
                  AND bTarget.versie EQ piVersie
                  AND bTarget.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bTarget THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offlijn &1 not found":u, piLijnnr), 404).

            IF pcDirection EQ "up":u THEN
                FIND LAST bNeighbor EXCLUSIVE-LOCK
                    WHERE bNeighbor.offnr EQ piOffnr
                      AND bNeighbor.versie EQ piVersie
                      AND bNeighbor.lijnnr LT piLijnnr NO-ERROR.
            ELSE
                FIND FIRST bNeighbor EXCLUSIVE-LOCK
                    WHERE bNeighbor.offnr EQ piOffnr
                      AND bNeighbor.versie EQ piVersie
                      AND bNeighbor.lijnnr GT piLijnnr NO-ERROR.

            IF NOT AVAILABLE bNeighbor THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    "No line to swap with in that direction":u, 404).

            ASSIGN
                iTargetLijnnr      = bTarget.lijnnr
                iNeighborLijnnr    = bNeighbor.lijnnr
                lTargetSubtotaal   = bTarget.subtotaal
                lNeighborSubtotaal = bNeighbor.subtotaal
                .

            /* Whichever of the two currently has subtotaal = TRUE, its
               lijnnr must not decrease as a result of the swap. */
            IF (lTargetSubtotaal   AND iNeighborLijnnr LT iTargetLijnnr) OR
               (lNeighborSubtotaal AND iTargetLijnnr   LT iNeighborLijnnr) THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    "Cannot move a subtotaal line upward above the lines it sums":u, 400).

            /* Swap via a temporary negative placeholder to avoid a
               transient collision on the (offnr, versie, lijnnr) unique
               index. */
            bTarget.lijnnr   = -1 * iTargetLijnnr.
            bNeighbor.lijnnr = iTargetLijnnr.
            bTarget.lijnnr   = iNeighborLijnnr.
        END.

        RETURN GetOfflijnen( piOffnr, piVersie ).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes an offlijn by offnr+versie+lijnnr.
        Errors : AppError code 404 - the parent offnr/versie doesn't exist,
                 or the lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteOfflijn( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureOfferteExists( piOffnr, piVersie ).

        DO TRANSACTION:
            FIND FIRST offlijn EXCLUSIVE-LOCK
                WHERE offlijn.offnr EQ piOffnr
                  AND offlijn.versie EQ piVersie
                  AND offlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE offlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offlijn &1/&2/&3 not found":u, piOffnr, piVersie, piLijnnr), 404).

            DELETE offlijn.
        END.

    END METHOD.

END CLASS.
