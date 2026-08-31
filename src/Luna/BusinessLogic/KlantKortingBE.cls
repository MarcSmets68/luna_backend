/*------------------------------------------------------------------------
    File        : KlantKortingBE.cls
    Purpose     : Business Entity for the "korting" (customer/article
                  discount) table - a child of `klant` (linked via klnr),
                  backing the "kortingen" list on the extended klant info
                  tab. This tab only ever exposes/creates rows where
                  swGroep = FALSE (per-article discounts, not group
                  discounts). Full CRUD.
    Field map (JSON key -> korting column):
                  klnr    -> klnr    (PK part, immutable, from parent klant -
                                      see the klnr type note below)
                  artnr   -> artnr   (PK part, required on create, immutable)
                  korting -> korting (0-100)
                  naam    -> n/a - Werkveld, NEVER stored/read from
                             korting.naam; populated server-side on every
                             read from artikel.omschr-n (Dutch description)
                             for the matching artnr, blank if the artikel
                             doesn't exist. Never accepted from the client
                             on create/update.
    Syntax      : Called from Luna.Web.KlantHandler (GET/POST/PUT/DELETE
                  /web/klant/{klnr}/korting and
                  /web/klant/{klnr}/korting/{artnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers
                  are expected to have already validated that the parent
                  klant (klnr) exists - see EnsureKlantExists.
                  IMPORTANT klnr type mismatch: `korting.klnr` is
                  CHARACTER(8) while `klant.klnr` is INTEGER. Investigated
                  live against the LunaNew database (a handful of existing
                  korting rows for klnr 1/10165/10545, see
                  scripts/InvestigateKortingSchema.p) - stored values are
                  PLAIN, NOT zero-padded (e.g. "1", "10165", not
                  "00000001"). FormatKlntForKorting() is the single helper
                  used for both the write value and every WHERE-clause
                  comparison, so reads/writes always agree. Reads guard
                  INTEGER(korting.klnr) with NO-ERROR in case of legacy
                  non-numeric junk rows - such rows are skipped rather than
                  crashing the request.
    Author(s)   : Devin
    Created     : 2026-08-27
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.KlantKortingBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttKorting NO-UNDO SERIALIZE-NAME 'items':u
        FIELD klnr    AS INTEGER   SERIALIZE-NAME 'klnr':u
        FIELD artnr   AS CHARACTER SERIALIZE-NAME 'artnr':u
        FIELD korting AS DECIMAL   SERIALIZE-NAME 'korting':u
        FIELD naam    AS CHARACTER SERIALIZE-NAME 'naam':u
        INDEX idx-artnr IS PRIMARY klnr artnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent klant doesn't exist.
                 Called at the start of every method here so korting CRUD
                 never silently operates on/under a non-existent customer.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureKlantExists( INPUT piKlnr AS INTEGER ):

        FIND FIRST klant NO-LOCK WHERE klant.klnr EQ piKlnr NO-ERROR.

        IF NOT AVAILABLE klant THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE('Klant &1 not found':u, piKlnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Single source of truth for how a klant.klnr (integer) is
                 represented in the CHARACTER(8) korting.klnr column - see
                 the class header for how this was determined (plain, not
                 zero-padded). Used for both writes and every WHERE-clause
                 comparison against korting.klnr so reads/writes never fall
                 out of sync.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER FormatKlntForKorting( INPUT piKlnr AS INTEGER ):

        RETURN STRING(piKlnr).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Looks up the Dutch description (omschr-n) of the artikel
                 matching pcArtnr, for the read-only "naam" (Werkveld)
                 field. Returns "" if the artikel doesn't exist.
        Notes  : NO-LOCK read-only.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER LookupArtikelNaam( INPUT pcArtnr AS CHARACTER ):

        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.

        IF AVAILABLE artikel THEN
            RETURN artikel.omschr-n.

        RETURN '':u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the fields from a `korting` buffer into a ttKorting
                 row, for use by every read method below. `klnr` is
                 converted back from the stored CHARACTER(8) value to an
                 INTEGER for the JSON response - guarded with NO-ERROR in
                 case of legacy non-numeric junk rows, in which case the
                 piKlnr the caller already validated/knows is used instead
                 (the row was found via a WHERE on FormatKlntForKorting(piKlnr)
                 in every caller, so this is always the correct value).
                 `naam` (Werkveld) is populated server-side via
                 LookupArtikelNaam - never read from the DB row itself.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( INPUT piKlnr AS INTEGER, BUFFER pbKorting FOR korting, BUFFER pbTt FOR ttKorting ):

        DEFINE VARIABLE iKlnr AS INTEGER NO-UNDO.

        iKlnr = INTEGER(pbKorting.klnr) NO-ERROR.
        IF iKlnr EQ ? THEN iKlnr = piKlnr.

        ASSIGN
            pbTt.klnr    = iKlnr
            pbTt.artnr   = pbKorting.artnr
            pbTt.korting = pbKorting.korting
            pbTt.naam    = LookupArtikelNaam(pbKorting.artnr)
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates a `korting` (discount percentage) value: must be
                 present, numeric, and within [0, 100] (Marc confirmed a
                 100% cap).
        Errors : AppError code 400 - missing/non-numeric/out-of-range.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL ValidateKortingValue( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE dKorting AS DECIMAL NO-UNDO.

        IF NOT poBody:Has('korting':u) THEN
            UNDO, THROW NEW Progress.Lang.AppError('korting is required':u, 400).

        dKorting = poBody:GetDecimal('korting':u) NO-ERROR.
        IF dKorting EQ ? OR ERROR-STATUS:ERROR THEN
            UNDO, THROW NEW Progress.Lang.AppError('korting must be numeric':u, 400).

        IF dKorting LT 0 OR dKorting GT 100 THEN
            UNDO, THROW NEW Progress.Lang.AppError('korting must be between 0 and 100':u, 400).

        RETURN dKorting.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every swGroep = FALSE korting row for the given
                 klnr, ordered by artnr.
        Notes  : NO-LOCK read-only.
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKortingen( INPUT piKlnr AS INTEGER ):

        DEFINE VARIABLE cKlnr AS CHARACTER NO-UNDO.

        EnsureKlantExists( piKlnr ).

        cKlnr = FormatKlntForKorting( piKlnr ).

        EMPTY TEMP-TABLE ttKorting.

        FOR EACH korting NO-LOCK
            WHERE korting.klnr EQ cKlnr
              AND korting.swGroep EQ FALSE
            BY korting.artnr:

            CREATE ttKorting.
            CopyToTt( piKlnr, BUFFER korting, BUFFER ttKorting ).
        END.

        RETURN TEMP-TABLE ttKorting:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single swGroep = FALSE korting row by
                 klnr+artnr, or an empty ttKorting if it doesn't exist (the
                 WebHandler turns that into a 404).
        Errors : AppError code 404 - the parent klnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetKorting( INPUT piKlnr AS INTEGER, INPUT pcArtnr AS CHARACTER ):

        DEFINE VARIABLE cKlnr AS CHARACTER NO-UNDO.

        EnsureKlantExists( piKlnr ).

        cKlnr = FormatKlntForKorting( piKlnr ).

        EMPTY TEMP-TABLE ttKorting.

        FIND FIRST korting NO-LOCK
            WHERE korting.klnr EQ cKlnr
              AND korting.artnr EQ pcArtnr
              AND korting.swGroep EQ FALSE NO-ERROR.

        IF AVAILABLE korting THEN
        DO:
            CREATE ttKorting.
            CopyToTt( piKlnr, BUFFER korting, BUFFER ttKorting ).
        END.

        RETURN TEMP-TABLE ttKorting:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new swGroep = FALSE korting row for the given
                 klnr. `artnr` is required in the body; `korting` is
                 required, numeric and within [0, 100]. No lijnnr-style
                 auto-allocation - artnr is the caller-supplied key.
        Errors : AppError code 404 - the parent klnr doesn't exist.
                 AppError code 400 - artnr missing/blank, or korting
                 missing/non-numeric/out-of-range.
                 AppError code 409 - klnr+artnr+swGroep=FALSE already
                 exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateKorting( INPUT piKlnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE cKlnr    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cArtnr   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dKorting AS DECIMAL   NO-UNDO.

        EnsureKlantExists( piKlnr ).

        EMPTY TEMP-TABLE ttKorting.

        IF NOT poBody:Has('artnr':u) OR poBody:GetCharacter('artnr':u) EQ '':u THEN
            UNDO, THROW NEW Progress.Lang.AppError('artnr is required':u, 400).

        cArtnr   = poBody:GetCharacter('artnr':u).
        dKorting = ValidateKortingValue( poBody ).
        cKlnr    = FormatKlntForKorting( piKlnr ).

        DO TRANSACTION:
            FIND FIRST korting EXCLUSIVE-LOCK
                WHERE korting.klnr EQ cKlnr
                  AND korting.artnr EQ cArtnr
                  AND korting.swGroep EQ FALSE NO-ERROR.
            IF AVAILABLE korting THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Korting for klnr &1 / artnr &2 already exists':u, piKlnr, cArtnr), 409).

            CREATE korting.
            ASSIGN
                korting.klnr    = cKlnr
                korting.artnr   = cArtnr
                korting.swGroep = FALSE
                korting.korting = dKorting
                .

            CREATE ttKorting.
            CopyToTt( piKlnr, BUFFER korting, BUFFER ttKorting ).
        END.

        RETURN TEMP-TABLE ttKorting:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates the `korting` value of an existing swGroep = FALSE
                 row. `artnr` is immutable; `naam` is never accepted from
                 the client (server-populated display field only).
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 artnr doesn't exist under it.
                 AppError code 400 - korting missing/non-numeric/out-of-range.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateKorting( INPUT piKlnr AS INTEGER, INPUT pcArtnr AS CHARACTER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE cKlnr    AS CHARACTER NO-UNDO.
        DEFINE VARIABLE dKorting AS DECIMAL   NO-UNDO.

        EnsureKlantExists( piKlnr ).

        cKlnr    = FormatKlntForKorting( piKlnr ).
        dKorting = ValidateKortingValue( poBody ).

        EMPTY TEMP-TABLE ttKorting.

        DO TRANSACTION:
            FIND FIRST korting EXCLUSIVE-LOCK
                WHERE korting.klnr EQ cKlnr
                  AND korting.artnr EQ pcArtnr
                  AND korting.swGroep EQ FALSE NO-ERROR.
            IF NOT AVAILABLE korting THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Korting &1/&2 not found':u, piKlnr, pcArtnr), 404).

            korting.korting = dKorting.

            CREATE ttKorting.
            CopyToTt( piKlnr, BUFFER korting, BUFFER ttKorting ).
        END.

        RETURN TEMP-TABLE ttKorting:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a swGroep = FALSE korting row by klnr+artnr.
        Errors : AppError code 404 - the parent klnr doesn't exist, or the
                 artnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteKorting( INPUT piKlnr AS INTEGER, INPUT pcArtnr AS CHARACTER ):

        DEFINE VARIABLE cKlnr AS CHARACTER NO-UNDO.

        EnsureKlantExists( piKlnr ).

        cKlnr = FormatKlntForKorting( piKlnr ).

        DO TRANSACTION:
            FIND FIRST korting EXCLUSIVE-LOCK
                WHERE korting.klnr EQ cKlnr
                  AND korting.artnr EQ pcArtnr
                  AND korting.swGroep EQ FALSE NO-ERROR.
            IF NOT AVAILABLE korting THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE('Korting &1/&2 not found':u, piKlnr, pcArtnr), 404).

            DELETE korting.
        END.

    END METHOD.

END CLASS.
