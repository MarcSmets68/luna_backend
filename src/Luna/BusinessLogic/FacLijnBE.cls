/*------------------------------------------------------------------------
    File        : FacLijnBE.cls
    Purpose     : Business Entity for the "faclijn" (invoice line) table -
                  owns full CRUD access for a curated core subset of fields
                  (identification, article, quantities, pricing, status).
                  `faclijn` is a child of `factuur` (linked via facnr) -
                  every method here always operates within the scope of a
                  single facnr. The `faclijn` table has ~55 fields in total;
                  only the subset below is exposed via the API for now.
    Field map (JSON key -> faclijn column):
                  facnr           -> facnr           (PK, immutable, from parent factuur)
                  lijnnr          -> lijnnr           (PK, required on create, immutable)
                  stempel         -> stempel          (raw code, no label mapping)
                  artnr           -> artnr
                  omschrijving    -> omschr
                  aantal          -> aantal
                  vprijs          -> verkoopprijs
                  aprijs          -> aankoopprijs
                  korting         -> korting
                  btwKode         -> btw-kode
                  bedrag          -> bedrag
                  datum           -> datum
                  uRef            -> u-ref
                  paknr           -> paknr           (pakbonnr)
                  bonnr           -> bonnr
                  klnr            -> klnr
                  groepnr         -> groepnr
                  magazijn        -> magazijn
                  subtotaal       -> subtotaal
                  kolomtitel      -> kolomtitel
                  infolijn        -> infolijn
                  opm             -> opm
    Syntax      : Called from Luna.Web.FactuurHandler (GET/POST/PUT/DELETE
                  /web/factuur/{facnr}/lijn and
                  /web/factuur/{facnr}/lijn/{lijnnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers
                  are expected to have already validated that the parent
                  factuur (facnr) exists - see EnsureFactuurExists. Deleting
                  a faclijn cascades to its `fac_led` rows so no orphan
                  LED-detail rows are left behind - that CRUD lives in
                  Luna.BusinessLogic.FacLedBE.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.FacLijnBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttFacLijn NO-UNDO SERIALIZE-NAME "items":u
        FIELD facnr        AS INTEGER   SERIALIZE-NAME "facnr":u
        FIELD lijnnr       AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD stempel      AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD aantal       AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD verkoopprijs AS DECIMAL   SERIALIZE-NAME "verkoopprijs":u
        FIELD aankoopprijs AS DECIMAL   SERIALIZE-NAME "aankoopprijs":u
        FIELD korting      AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD btwKode      AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag       AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD datum        AS DATE      SERIALIZE-NAME "datum":u
        FIELD uRef         AS CHARACTER SERIALIZE-NAME "uRef":u
        FIELD paknr        AS INTEGER   SERIALIZE-NAME "paknr":u
        FIELD bonnr        AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD klnr         AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD groepnr      AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD magazijn     AS CHARACTER SERIALIZE-NAME "magazijn":u
        FIELD subtotaal    AS LOGICAL   SERIALIZE-NAME "subtotaal":u
        FIELD kolomtitel   AS LOGICAL   SERIALIZE-NAME "kolomtitel":u
        FIELD infolijn     AS LOGICAL   SERIALIZE-NAME "infolijn":u
        FIELD opm          AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-lijnnr IS PRIMARY facnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent factuur (facnr) doesn't
                 exist (or is a credit note - type EQ FALSE, treated
                 identically to "not found", same as FactuurBE). Called at
                 the start of every method here so faclijn CRUD never
                 silently operates on/under a non-existent invoice.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureFactuurExists( INPUT piFacnr AS INTEGER ):

        FIND FIRST factuur NO-LOCK
            WHERE factuur.facnr EQ piFacnr
              AND factuur.type EQ TRUE NO-ERROR.

        IF NOT AVAILABLE factuur THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Factuur &1 not found":u, piFacnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a `faclijn` buffer
                 into a ttFacLijn row, for use by every read/write method
                 below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbFacLijn FOR faclijn, BUFFER pbTt FOR ttFacLijn ):

        ASSIGN
            pbTt.facnr        = pbFacLijn.facnr
            pbTt.lijnnr       = pbFacLijn.lijnnr
            pbTt.stempel      = pbFacLijn.stempel
            pbTt.artnr        = pbFacLijn.artnr
            pbTt.omschrijving = pbFacLijn.omschr
            pbTt.aantal       = pbFacLijn.aantal
            pbTt.verkoopprijs = pbFacLijn.vprijs
            pbTt.aankoopprijs = pbFacLijn.aprijs
            pbTt.korting      = pbFacLijn.korting
            pbTt.btwKode      = pbFacLijn.btw-kode
            pbTt.bedrag       = pbFacLijn.bedrag
            pbTt.datum        = pbFacLijn.datum
            pbTt.uRef         = pbFacLijn.u-ref
            pbTt.paknr        = pbFacLijn.paknr
            pbTt.bonnr        = pbFacLijn.bonnr
            pbTt.klnr         = pbFacLijn.klnr
            pbTt.groepnr      = pbFacLijn.groepnr
            pbTt.magazijn     = pbFacLijn.magazijn
            pbTt.subtotaal    = pbFacLijn.subtotaal
            pbTt.kolomtitel   = pbFacLijn.kolomtitel
            pbTt.infolijn     = pbFacLijn.infolijn
            pbTt.opm          = pbFacLijn.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `faclijn` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `facnr`/`lijnnr` are never touched here - they are set once
                 on create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbFacLijn FOR faclijn ):

        IF poBody:Has("stempel":u)      THEN pbFacLijn.stempel   = poBody:GetCharacter("stempel":u).
        IF poBody:Has("artnr":u)        THEN pbFacLijn.artnr     = poBody:GetCharacter("artnr":u).
        IF poBody:Has("omschrijving":u) THEN pbFacLijn.omschr    = poBody:GetCharacter("omschrijving":u).
        IF poBody:Has("aantal":u)       THEN pbFacLijn.aantal    = poBody:GetDecimal("aantal":u).
        IF poBody:Has("verkoopprijs":u) THEN pbFacLijn.vprijs    = poBody:GetDecimal("verkoopprijs":u).
        IF poBody:Has("aankoopprijs":u) THEN pbFacLijn.aprijs    = poBody:GetDecimal("aankoopprijs":u).
        IF poBody:Has("korting":u)      THEN pbFacLijn.korting   = poBody:GetDecimal("korting":u).
        IF poBody:Has("btwKode":u)      THEN pbFacLijn.btw-kode  = poBody:GetCharacter("btwKode":u).
        IF poBody:Has("bedrag":u)       THEN pbFacLijn.bedrag    = poBody:GetDecimal("bedrag":u).
        IF poBody:Has("datum":u)        THEN pbFacLijn.datum     = poBody:GetDate("datum":u).
        IF poBody:Has("uRef":u)         THEN pbFacLijn.u-ref     = poBody:GetCharacter("uRef":u).
        IF poBody:Has("paknr":u)        THEN pbFacLijn.paknr     = poBody:GetInteger("paknr":u).
        IF poBody:Has("bonnr":u)        THEN pbFacLijn.bonnr     = poBody:GetInteger("bonnr":u).
        IF poBody:Has("klnr":u)         THEN pbFacLijn.klnr      = poBody:GetInteger("klnr":u).
        IF poBody:Has("groepnr":u)      THEN pbFacLijn.groepnr   = poBody:GetInteger("groepnr":u).
        IF poBody:Has("magazijn":u)     THEN pbFacLijn.magazijn  = poBody:GetCharacter("magazijn":u).
        IF poBody:Has("subtotaal":u)    THEN pbFacLijn.subtotaal = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u)   THEN pbFacLijn.kolomtitel = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)     THEN pbFacLijn.infolijn  = poBody:GetLogical("infolijn":u).
        IF poBody:Has("opm":u)          THEN pbFacLijn.opm       = poBody:GetCharacter("opm":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every faclijn row for the given facnr, ordered by
                 lijnnr.
        Notes  : NO-LOCK read-only. Uses the faclijn-x1 (unique) index.
        Errors : AppError code 404 - the parent facnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFacLijnen( INPUT piFacnr AS INTEGER ):

        EnsureFactuurExists( piFacnr ).

        EMPTY TEMP-TABLE ttFacLijn.

        FOR EACH faclijn NO-LOCK
            WHERE faclijn.facnr EQ piFacnr
            BY faclijn.lijnnr:

            CREATE ttFacLijn.
            CopyToTt( BUFFER faclijn, BUFFER ttFacLijn ).
        END.

        RETURN TEMP-TABLE ttFacLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single faclijn by facnr+lijnnr, or an empty
                 ttFacLijn if it doesn't exist (the WebHandler turns that
                 into a 404).
        Errors : AppError code 404 - the parent facnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFacLijn( INPUT piFacnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureFactuurExists( piFacnr ).

        EMPTY TEMP-TABLE ttFacLijn.

        FIND FIRST faclijn NO-LOCK
            WHERE faclijn.facnr EQ piFacnr
              AND faclijn.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE faclijn THEN
        DO:
            CREATE ttFacLijn.
            CopyToTt( BUFFER faclijn, BUFFER ttFacLijn ).
        END.

        RETURN TEMP-TABLE ttFacLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new faclijn under the given facnr. `lijnnr` is
                 required in the body (positive integer) and must not
                 already exist for that facnr.
        Errors : AppError code 404 - the parent facnr doesn't exist.
                 AppError code 400 - lijnnr missing/invalid.
                 AppError code 409 - lijnnr already exists for this factuur.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateFacLijn( INPUT piFacnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iLijnnr AS INTEGER NO-UNDO.

        EnsureFactuurExists( piFacnr ).

        EMPTY TEMP-TABLE ttFacLijn.

        IF NOT poBody:Has("lijnnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("lijnnr is required":u, 400).

        iLijnnr = poBody:GetInteger("lijnnr":u) NO-ERROR.
        IF iLijnnr EQ ? OR iLijnnr LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("lijnnr must be a positive integer":u, 400).

        DO TRANSACTION:
            FIND FIRST faclijn EXCLUSIVE-LOCK
                WHERE faclijn.facnr EQ piFacnr
                  AND faclijn.lijnnr EQ iLijnnr NO-ERROR.
            IF AVAILABLE faclijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Faclijn &1/&2 already exists":u, piFacnr, iLijnnr), 409).

            CREATE faclijn.
            ASSIGN
                faclijn.facnr  = piFacnr
                faclijn.lijnnr = iLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER faclijn ).

            CREATE ttFacLijn.
            CopyToTt( BUFFER faclijn, BUFFER ttFacLijn ).
        END.

        RETURN TEMP-TABLE ttFacLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing faclijn. Only fields present in the
                 JSON body are changed (partial update); `facnr`/`lijnnr`
                 are immutable.
        Errors : AppError code 404 - the parent facnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateFacLijn(
        INPUT piFacnr  AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        EnsureFactuurExists( piFacnr ).

        EMPTY TEMP-TABLE ttFacLijn.

        DO TRANSACTION:
            FIND FIRST faclijn EXCLUSIVE-LOCK
                WHERE faclijn.facnr EQ piFacnr
                  AND faclijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE faclijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Faclijn &1/&2 not found":u, piFacnr, piLijnnr), 404).

            ApplyFields( INPUT poBody, BUFFER faclijn ).

            CREATE ttFacLijn.
            CopyToTt( BUFFER faclijn, BUFFER ttFacLijn ).
        END.

        RETURN TEMP-TABLE ttFacLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a faclijn by facnr+lijnnr, cascading to every
                 `fac_led` row for that facnr+lijnnr so no orphan LED-detail
                 rows are left behind.
        Errors : AppError code 404 - the parent facnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteFacLijn( INPUT piFacnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureFactuurExists( piFacnr ).

        DO TRANSACTION:
            FIND FIRST faclijn EXCLUSIVE-LOCK
                WHERE faclijn.facnr EQ piFacnr
                  AND faclijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE faclijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Faclijn &1/&2 not found":u, piFacnr, piLijnnr), 404).

            FOR EACH fac_led EXCLUSIVE-LOCK
                WHERE fac_led.facnr  EQ piFacnr
                  AND fac_led.lijnnr EQ piLijnnr:
                DELETE fac_led.
            END.

            DELETE faclijn.
        END.

    END METHOD.

END CLASS.
