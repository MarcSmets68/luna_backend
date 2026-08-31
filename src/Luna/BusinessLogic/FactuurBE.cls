/*------------------------------------------------------------------------
    File        : FactuurBE.cls
    Purpose     : Business Entity for the "factuur" (invoice) table - owns
                  full CRUD access for a curated core subset of fields
                  (identification, customer, amounts, status). The
                  `factuur` table has ~60 fields in total; only the subset
                  below is exposed via the API for now. v1 only ever
                  operates on invoices (factuur.type EQ TRUE) - credit notes
                  (type EQ FALSE) are out of scope and are hard-coded out of
                  every query/lookup/write in this class; `type` itself is
                  not settable via the API and is always TRUE on create.
    Field map (JSON key -> factuur column):
                  facnr       -> facnr       (PK, required on create, immutable)
                  type        -> type        (not settable - always TRUE, see above)
                  stempel     -> stempel     (raw code, no label mapping)
                  datum       -> datum
                  klnr        -> klnr
                  naam        -> naam
                  adres       -> adres
                  postnr      -> postnr
                  stad        -> stad
                  munt        -> munt
                  uRef        -> u-ref
                  oRef        -> o-ref
                  vervaldat   -> vervaldat
                  swBetaald   -> swBetaald
                  bdatum      -> bdatum
                  nBedrag     -> n-bedrag     (netto bedrag)
                  bBedrag     -> b-bedrag     (bruto/gross bedrag)
                  totBtw      -> tot-btw
                  totaal      -> totaal
                  voorschot   -> voorschot
                  swFactuur   -> swFactuur
                  projectnr   -> projectnr
                  opm         -> opm
    Notes       : Same pagination approach as Luna.BusinessLogic.OfferteBE:
                  GetOffertes() / Luna.BusinessLogic.BonBE:GetBonnen() - this
                  deliberately does NOT compute an exact total count,
                  instead it stops scanning as soon as it has one extra row
                  beyond the requested page and reports that via plHasMore.
                  klnr uses the existing factuur-x2 index, datum uses
                  factuur-x4 and projectnr uses factuur-x5; a naam-only
                  filter scans every candidate row and should be combined
                  with klnr/datum/projectnr where possible.
                  Deleting a factuur cascades to its `faclijn` rows (and, via
                  Luna.BusinessLogic.FacLedBE, their `fac_led` rows) so no
                  orphan lines/led-detail rows are left behind - line CRUD
                  itself lives in Luna.BusinessLogic.FacLijnBE.
    Syntax      : Called from Luna.Web.FactuurHandler (GET/POST/PUT/DELETE
                  /web/factuur and /web/factuur/{facnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes.
    Author(s)   : Devin
    Created     : 2026-08-11
    Updated     : 2026-08-12 - added full factuur CRUD (create/update/delete),
                  delete cascades to faclijn/fac_led.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.FactuurBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results the WebHandler unwraps the first (and only)
       entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttFactuur NO-UNDO SERIALIZE-NAME "items":u
        FIELD facnr      AS INTEGER   SERIALIZE-NAME "facnr":u
        FIELD type       AS LOGICAL   SERIALIZE-NAME "type":u
        FIELD stempel    AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD datum      AS DATE      SERIALIZE-NAME "datum":u
        FIELD klnr       AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam       AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD adres      AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr     AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad       AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD munt       AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD uRef       AS CHARACTER SERIALIZE-NAME "uRef":u
        FIELD oRef       AS CHARACTER SERIALIZE-NAME "oRef":u
        FIELD vervaldat  AS DATE      SERIALIZE-NAME "vervaldat":u
        FIELD swBetaald  AS LOGICAL   SERIALIZE-NAME "swBetaald":u
        FIELD bdatum     AS DATE      SERIALIZE-NAME "bdatum":u
        FIELD nBedrag    AS DECIMAL   SERIALIZE-NAME "nBedrag":u
        FIELD bBedrag    AS DECIMAL   SERIALIZE-NAME "bBedrag":u
        FIELD totBtw     AS DECIMAL   SERIALIZE-NAME "totBtw":u
        FIELD totaal     AS DECIMAL   SERIALIZE-NAME "totaal":u
        FIELD voorschot  AS DECIMAL   SERIALIZE-NAME "voorschot":u
        FIELD swFactuur  AS LOGICAL   SERIALIZE-NAME "swFactuur":u
        FIELD projectnr  AS INTEGER   SERIALIZE-NAME "projectnr":u
        FIELD opm        AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-facnr IS PRIMARY facnr DESCENDING.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a factuur buffer into
                 a ttFactuur row, for use by every read method below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbFactuur FOR factuur, BUFFER pbTt FOR ttFactuur ):

        ASSIGN
            pbTt.facnr      = pbFactuur.facnr
            pbTt.type       = pbFactuur.type
            pbTt.stempel    = pbFactuur.stempel
            pbTt.datum      = pbFactuur.datum
            pbTt.klnr       = pbFactuur.klnr
            pbTt.naam       = pbFactuur.naam
            pbTt.adres      = pbFactuur.adres
            pbTt.postnr     = pbFactuur.postnr
            pbTt.stad       = pbFactuur.stad
            pbTt.munt       = pbFactuur.munt
            pbTt.uRef       = pbFactuur.u-ref
            pbTt.oRef       = pbFactuur.o-ref
            pbTt.vervaldat  = pbFactuur.vervaldat
            pbTt.swBetaald  = pbFactuur.swBetaald
            pbTt.bdatum     = pbFactuur.bdatum
            pbTt.nBedrag    = pbFactuur.n-bedrag
            pbTt.bBedrag    = pbFactuur.b-bedrag
            pbTt.totBtw     = pbFactuur.tot-btw
            pbTt.totaal     = pbFactuur.totaal
            pbTt.voorschot  = pbFactuur.voorschot
            pbTt.swFactuur  = pbFactuur.swFactuur
            pbTt.projectnr  = pbFactuur.projectnr
            pbTt.opm        = pbFactuur.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `factuur` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `facnr` is never touched here - it is set once on create
                 and is immutable. `type` is never settable via the API -
                 v1 only ever operates on invoices, so it is always TRUE
                 (set on create in CreateFactuur, never touched again here).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbFactuur FOR factuur ):

        IF poBody:Has("stempel":u)   THEN pbFactuur.stempel   = poBody:GetCharacter("stempel":u).
        IF poBody:Has("datum":u)     THEN pbFactuur.datum     = poBody:GetDate("datum":u).
        IF poBody:Has("klnr":u)      THEN pbFactuur.klnr      = poBody:GetInteger("klnr":u).
        IF poBody:Has("naam":u)      THEN pbFactuur.naam      = poBody:GetCharacter("naam":u).
        IF poBody:Has("adres":u)     THEN pbFactuur.adres     = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)    THEN pbFactuur.postnr    = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)      THEN pbFactuur.stad      = poBody:GetCharacter("stad":u).
        IF poBody:Has("munt":u)      THEN pbFactuur.munt      = poBody:GetCharacter("munt":u).
        IF poBody:Has("uRef":u)      THEN pbFactuur.u-ref     = poBody:GetCharacter("uRef":u).
        IF poBody:Has("oRef":u)      THEN pbFactuur.o-ref     = poBody:GetCharacter("oRef":u).
        IF poBody:Has("vervaldat":u) THEN pbFactuur.vervaldat = poBody:GetDate("vervaldat":u).
        IF poBody:Has("swBetaald":u) THEN pbFactuur.swBetaald = poBody:GetLogical("swBetaald":u).
        IF poBody:Has("bdatum":u)    THEN pbFactuur.bdatum    = poBody:GetDate("bdatum":u).
        IF poBody:Has("nBedrag":u)   THEN pbFactuur.n-bedrag  = poBody:GetDecimal("nBedrag":u).
        IF poBody:Has("bBedrag":u)   THEN pbFactuur.b-bedrag  = poBody:GetDecimal("bBedrag":u).
        IF poBody:Has("totBtw":u)    THEN pbFactuur.tot-btw   = poBody:GetDecimal("totBtw":u).
        IF poBody:Has("totaal":u)    THEN pbFactuur.totaal    = poBody:GetDecimal("totaal":u).
        IF poBody:Has("voorschot":u) THEN pbFactuur.voorschot = poBody:GetDecimal("voorschot":u).
        IF poBody:Has("swFactuur":u) THEN pbFactuur.swFactuur = poBody:GetLogical("swFactuur":u).
        IF poBody:Has("projectnr":u) THEN pbFactuur.projectnr = poBody:GetInteger("projectnr":u).
        IF poBody:Has("opm":u)       THEN pbFactuur.opm       = poBody:GetCharacter("opm":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of factuur rows (newest datum, then facnr,
                 first), optionally filtered by klnr (exact), naam
                 (substring), datum (exact) and projectnr (exact). Only
                 invoices are returned - factuur.type EQ TRUE is hard-coded
                 here, credit notes (type EQ FALSE) are never returned by
                 this method regardless of the caller's filters.
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200).
                 Same approach as Luna.BusinessLogic.OfferteBE:GetOffertes() -
                 this deliberately does NOT compute an exact total count,
                 instead it stops scanning as soon as it has one extra row
                 beyond the requested page and reports that via
                 plHasMore. klnr uses the existing factuur-x2 index, datum
                 uses factuur-x4 and projectnr uses factuur-x5; a naam-only
                 filter scans every candidate row and should be combined
                 with klnr/datum/projectnr where possible.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFacturen(
        INPUT  piKlnr      AS INTEGER,
        INPUT  pcNaam      AS CHARACTER,
        INPUT  pdDatum     AS DATE,
        INPUT  piProjectnr AS INTEGER,
        INPUT  piPage      AS INTEGER,
        INPUT  piPageSize  AS INTEGER,
        OUTPUT plHasMore   AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttFactuur.

        ASSIGN
            pcNaam    = UPPER(TRIM(pcNaam))
            iSkip     = (piPage - 1) * piPageSize
            iSeen     = 0
            iTaken    = 0
            plHasMore = FALSE
            .

        FOR EACH factuur NO-LOCK
            WHERE (piKlnr LE 0 OR factuur.klnr EQ piKlnr)
              AND (pcNaam EQ "":u OR INDEX(UPPER(factuur.naam), pcNaam) GT 0)
              AND (piProjectnr LE 0 OR factuur.projectnr EQ piProjectnr)
              AND (pdDatum EQ ? OR factuur.datum EQ pdDatum)
              AND factuur.type EQ TRUE
            BY factuur.datum DESCENDING BY factuur.facnr DESCENDING:

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttFactuur.
            CopyToTt( BUFFER factuur, BUFFER ttFactuur ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttFactuur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single factuur by facnr, or an empty ttFactuur if
                 it doesn't exist or is a credit note (type EQ FALSE) - both
                 cases are treated identically and the WebHandler turns
                 either into a 404.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFactuur( INPUT piFacnr AS INTEGER ):

        EMPTY TEMP-TABLE ttFactuur.

        FIND FIRST factuur NO-LOCK
            WHERE factuur.facnr EQ piFacnr
              AND factuur.type EQ TRUE NO-ERROR.

        IF AVAILABLE factuur THEN
        DO:
            CREATE ttFactuur.
            CopyToTt( BUFFER factuur, BUFFER ttFactuur ).
        END.

        RETURN TEMP-TABLE ttFactuur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new factuur. `facnr` is required in the body
                 (positive integer) and must not already exist as any
                 factuur row (invoice or credit note - facnr is unique
                 across both via factuur-x1). `type` is always set to TRUE
                 (invoice) regardless of the body - v1 never creates credit
                 notes via the API.
        Errors : AppError code 400 - facnr missing/not a positive integer.
                 AppError code 409 - facnr already exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateFactuur( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iFacnr AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttFactuur.

        IF NOT poBody:Has("facnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("facnr is required":u, 400).

        iFacnr = poBody:GetInteger("facnr":u) NO-ERROR.
        IF iFacnr EQ ? OR iFacnr LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("facnr must be a positive integer":u, 400).

        DO TRANSACTION:
            FIND FIRST factuur EXCLUSIVE-LOCK WHERE factuur.facnr EQ iFacnr NO-ERROR.
            IF AVAILABLE factuur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Factuur &1 already exists":u, iFacnr), 409).

            CREATE factuur.
            ASSIGN
                factuur.facnr = iFacnr
                factuur.type  = TRUE
                .

            ApplyFields( INPUT poBody, BUFFER factuur ).

            CREATE ttFactuur.
            CopyToTt( BUFFER factuur, BUFFER ttFactuur ).
        END.

        RETURN TEMP-TABLE ttFactuur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing factuur. Only fields present in the
                 JSON body are changed (partial update); `facnr` and `type`
                 are immutable/not settable (see ApplyFields).
        Errors : AppError code 404 - facnr not found, or it's a credit note
                 (type EQ FALSE - treated identically to "not found", same
                 as GetFactuur).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateFactuur( INPUT piFacnr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttFactuur.

        DO TRANSACTION:
            FIND FIRST factuur EXCLUSIVE-LOCK
                WHERE factuur.facnr EQ piFacnr
                  AND factuur.type EQ TRUE NO-ERROR.
            IF NOT AVAILABLE factuur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Factuur &1 not found":u, piFacnr), 404).

            ApplyFields( INPUT poBody, BUFFER factuur ).

            CREATE ttFactuur.
            CopyToTt( BUFFER factuur, BUFFER ttFactuur ).
        END.

        RETURN TEMP-TABLE ttFactuur:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a factuur by facnr, cascading to every `faclijn`
                 row for that facnr and, for each of those, every `fac_led`
                 row - so no orphan lines or LED-detail rows are left
                 behind.
        Errors : AppError code 404 - facnr not found, or it's a credit note
                 (treated identically to "not found", same as GetFactuur).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteFactuur( INPUT piFacnr AS INTEGER ):

        DO TRANSACTION:
            FIND FIRST factuur EXCLUSIVE-LOCK
                WHERE factuur.facnr EQ piFacnr
                  AND factuur.type EQ TRUE NO-ERROR.
            IF NOT AVAILABLE factuur THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Factuur &1 not found":u, piFacnr), 404).

            FOR EACH faclijn EXCLUSIVE-LOCK WHERE faclijn.facnr EQ piFacnr:
                FOR EACH fac_led EXCLUSIVE-LOCK
                    WHERE fac_led.facnr  EQ faclijn.facnr
                      AND fac_led.lijnnr EQ faclijn.lijnnr:
                    DELETE fac_led.
                END.
                DELETE faclijn.
            END.

            DELETE factuur.
        END.

    END METHOD.

END CLASS.
