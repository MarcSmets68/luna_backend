/*------------------------------------------------------------------------
    File        : FacLedBE.cls
    Purpose     : Business Entity for the "fac_led" (invoice line LED
                  configuration detail) table - owns full CRUD access for a
                  curated core subset of fields (identification, article,
                  dimensions, pricing, routing/config). `fac_led` is a child
                  of `faclijn` (linked via facnr+lijnnr) - every method here
                  always operates within the scope of a single
                  facnr+lijnnr. The `fac_led` table has ~35 fields in total;
                  only the subset below is exposed via the API for now.
    Field map (JSON key -> fac_led column):
                  facnr        -> facnr        (PK, immutable, from parent faclijn)
                  lijnnr       -> lijnnr        (PK, immutable, from parent faclijn)
                  groepnr      -> groepnr       (PK, required on create, immutable)
                  ledLijn      -> led_lijn      (PK, required on create, immutable)
                  artnr        -> artnr
                  soort        -> soort
                  kode         -> kode
                  lengte       -> lengte
                  aantal       -> aantal
                  lMaat        -> Lmaat
                  rMaat        -> Rmaat
                  prijs        -> prijs
                  montagePrijs -> montage-prijs
                  circuit      -> circuit
                  comp         -> comp
                  reflector    -> reflector
                  sturing      -> sturing
                  locatie      -> locatie
                  datum        -> datum
                  opm          -> opm
    Syntax      : Called from Luna.Web.FactuurHandler (GET/POST/PUT/DELETE
                  /web/factuur/{facnr}/lijn/{lijnnr}/led and
                  /web/factuur/{facnr}/lijn/{lijnnr}/led/{groepnr}/{ledLijn})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers
                  are expected to have already validated that the parent
                  faclijn (facnr+lijnnr) exists - see EnsureFacLijnExists.
    Author(s)   : Devin
    Created     : 2026-08-12
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.FacLedBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttFacLed NO-UNDO SERIALIZE-NAME "items":u
        FIELD facnr        AS INTEGER   SERIALIZE-NAME "facnr":u
        FIELD lijnnr       AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD groepnr      AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD ledLijn      AS INTEGER   SERIALIZE-NAME "ledLijn":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD soort        AS CHARACTER SERIALIZE-NAME "soort":u
        FIELD kode         AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD lengte       AS DECIMAL   SERIALIZE-NAME "lengte":u
        FIELD aantal       AS INTEGER   SERIALIZE-NAME "aantal":u
        FIELD lMaat        AS DECIMAL   SERIALIZE-NAME "lMaat":u
        FIELD rMaat        AS DECIMAL   SERIALIZE-NAME "rMaat":u
        FIELD prijs        AS DECIMAL   SERIALIZE-NAME "prijs":u
        FIELD montagePrijs AS DECIMAL   SERIALIZE-NAME "montagePrijs":u
        FIELD circuit      AS INTEGER   SERIALIZE-NAME "circuit":u
        FIELD comp         AS CHARACTER SERIALIZE-NAME "comp":u
        FIELD reflector    AS LOGICAL   SERIALIZE-NAME "reflector":u
        FIELD sturing      AS CHARACTER SERIALIZE-NAME "sturing":u
        FIELD locatie      AS CHARACTER SERIALIZE-NAME "locatie":u
        FIELD datum        AS DATE      SERIALIZE-NAME "datum":u
        FIELD opm          AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-led IS PRIMARY facnr lijnnr groepnr ledLijn.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent faclijn (facnr+lijnnr)
                 doesn't exist. Called at the start of every method here so
                 fac_led CRUD never silently operates on/under a
                 non-existent invoice line.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureFacLijnExists( INPUT piFacnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        FIND FIRST faclijn NO-LOCK
            WHERE faclijn.facnr EQ piFacnr
              AND faclijn.lijnnr EQ piLijnnr NO-ERROR.

        IF NOT AVAILABLE faclijn THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Faclijn &1/&2 not found":u, piFacnr, piLijnnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a `fac_led` buffer
                 into a ttFacLed row, for use by every read/write method
                 below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbFacLed FOR fac_led, BUFFER pbTt FOR ttFacLed ):

        ASSIGN
            pbTt.facnr        = pbFacLed.facnr
            pbTt.lijnnr       = pbFacLed.lijnnr
            pbTt.groepnr      = pbFacLed.groepnr
            pbTt.ledLijn      = pbFacLed.led_lijn
            pbTt.artnr        = pbFacLed.artnr
            pbTt.soort        = pbFacLed.soort
            pbTt.kode         = pbFacLed.kode
            pbTt.lengte       = pbFacLed.lengte
            pbTt.aantal       = pbFacLed.aantal
            pbTt.lMaat        = pbFacLed.Lmaat
            pbTt.rMaat        = pbFacLed.Rmaat
            pbTt.prijs        = pbFacLed.prijs
            pbTt.montagePrijs = pbFacLed.montage-prijs
            pbTt.circuit      = pbFacLed.circuit
            pbTt.comp         = pbFacLed.comp
            pbTt.reflector    = pbFacLed.reflector
            pbTt.sturing      = pbFacLed.sturing
            pbTt.locatie      = pbFacLed.locatie
            pbTt.datum        = pbFacLed.datum
            pbTt.opm          = pbFacLed.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `fac_led` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `facnr`/`lijnnr`/`groepnr`/`ledLijn` are never touched here
                 - they are set once on create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbFacLed FOR fac_led ):

        IF poBody:Has("artnr":u)        THEN pbFacLed.artnr         = poBody:GetCharacter("artnr":u).
        IF poBody:Has("soort":u)        THEN pbFacLed.soort         = poBody:GetCharacter("soort":u).
        IF poBody:Has("kode":u)         THEN pbFacLed.kode          = poBody:GetCharacter("kode":u).
        IF poBody:Has("lengte":u)       THEN pbFacLed.lengte        = poBody:GetDecimal("lengte":u).
        IF poBody:Has("aantal":u)       THEN pbFacLed.aantal        = poBody:GetInteger("aantal":u).
        IF poBody:Has("lMaat":u)        THEN pbFacLed.Lmaat         = poBody:GetDecimal("lMaat":u).
        IF poBody:Has("rMaat":u)        THEN pbFacLed.Rmaat         = poBody:GetDecimal("rMaat":u).
        IF poBody:Has("prijs":u)        THEN pbFacLed.prijs         = poBody:GetDecimal("prijs":u).
        IF poBody:Has("montagePrijs":u) THEN pbFacLed.montage-prijs = poBody:GetDecimal("montagePrijs":u).
        IF poBody:Has("circuit":u)      THEN pbFacLed.circuit       = poBody:GetInteger("circuit":u).
        IF poBody:Has("comp":u)         THEN pbFacLed.comp          = poBody:GetCharacter("comp":u).
        IF poBody:Has("reflector":u)    THEN pbFacLed.reflector     = poBody:GetLogical("reflector":u).
        IF poBody:Has("sturing":u)      THEN pbFacLed.sturing       = poBody:GetCharacter("sturing":u).
        IF poBody:Has("locatie":u)      THEN pbFacLed.locatie       = poBody:GetCharacter("locatie":u).
        IF poBody:Has("datum":u)        THEN pbFacLed.datum         = poBody:GetDate("datum":u).
        IF poBody:Has("opm":u)          THEN pbFacLed.opm           = poBody:GetCharacter("opm":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every fac_led row for the given facnr+lijnnr,
                 ordered by groepnr then led_lijn.
        Notes  : NO-LOCK read-only. Uses the fac_led-x1 (unique) index.
        Errors : AppError code 404 - the parent facnr/lijnnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFacLeds( INPUT piFacnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureFacLijnExists( piFacnr, piLijnnr ).

        EMPTY TEMP-TABLE ttFacLed.

        FOR EACH fac_led NO-LOCK
            WHERE fac_led.facnr EQ piFacnr
              AND fac_led.lijnnr EQ piLijnnr
            BY fac_led.groepnr BY fac_led.led_lijn:

            CREATE ttFacLed.
            CopyToTt( BUFFER fac_led, BUFFER ttFacLed ).
        END.

        RETURN TEMP-TABLE ttFacLed:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single fac_led by facnr+lijnnr+groepnr+led_lijn,
                 or an empty ttFacLed if it doesn't exist (the WebHandler
                 turns that into a 404).
        Errors : AppError code 404 - the parent facnr/lijnnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetFacLed(
        INPUT piFacnr   AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER ):

        EnsureFacLijnExists( piFacnr, piLijnnr ).

        EMPTY TEMP-TABLE ttFacLed.

        FIND FIRST fac_led NO-LOCK
            WHERE fac_led.facnr   EQ piFacnr
              AND fac_led.lijnnr  EQ piLijnnr
              AND fac_led.groepnr EQ piGroepnr
              AND fac_led.led_lijn EQ piLedLijn NO-ERROR.

        IF AVAILABLE fac_led THEN
        DO:
            CREATE ttFacLed.
            CopyToTt( BUFFER fac_led, BUFFER ttFacLed ).
        END.

        RETURN TEMP-TABLE ttFacLed:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new fac_led under the given facnr+lijnnr.
                 `groepnr` and `ledLijn` are required in the body (integers
                 >= 0) and their combination must not already exist for
                 that facnr+lijnnr.
        Errors : AppError code 404 - the parent facnr/lijnnr doesn't exist.
                 AppError code 400 - groepnr/ledLijn missing/invalid.
                 AppError code 409 - groepnr+ledLijn already exists for
                 this faclijn.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateFacLed(
        INPUT piFacnr  AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        DEFINE VARIABLE iGroepnr AS INTEGER NO-UNDO.
        DEFINE VARIABLE iLedLijn AS INTEGER NO-UNDO.

        EnsureFacLijnExists( piFacnr, piLijnnr ).

        EMPTY TEMP-TABLE ttFacLed.

        IF NOT poBody:Has("groepnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("groepnr is required":u, 400).

        IF NOT poBody:Has("ledLijn":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("ledLijn is required":u, 400).

        iGroepnr = poBody:GetInteger("groepnr":u) NO-ERROR.
        IF iGroepnr EQ ? OR iGroepnr LT 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("groepnr must be a non-negative integer":u, 400).

        iLedLijn = poBody:GetInteger("ledLijn":u) NO-ERROR.
        IF iLedLijn EQ ? OR iLedLijn LT 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("ledLijn must be a non-negative integer":u, 400).

        DO TRANSACTION:
            FIND FIRST fac_led EXCLUSIVE-LOCK
                WHERE fac_led.facnr   EQ piFacnr
                  AND fac_led.lijnnr  EQ piLijnnr
                  AND fac_led.groepnr EQ iGroepnr
                  AND fac_led.led_lijn EQ iLedLijn NO-ERROR.
            IF AVAILABLE fac_led THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Fac_led &1/&2/&3/&4 already exists":u, piFacnr, piLijnnr, iGroepnr, iLedLijn), 409).

            CREATE fac_led.
            ASSIGN
                fac_led.facnr    = piFacnr
                fac_led.lijnnr   = piLijnnr
                fac_led.groepnr  = iGroepnr
                fac_led.led_lijn = iLedLijn
                .

            ApplyFields( INPUT poBody, BUFFER fac_led ).

            CREATE ttFacLed.
            CopyToTt( BUFFER fac_led, BUFFER ttFacLed ).
        END.

        RETURN TEMP-TABLE ttFacLed:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing fac_led. Only fields present in the
                 JSON body are changed (partial update);
                 `facnr`/`lijnnr`/`groepnr`/`ledLijn` are immutable.
        Errors : AppError code 404 - the parent facnr/lijnnr doesn't exist,
                 or the groepnr+ledLijn doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateFacLed(
        INPUT piFacnr   AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER,
        INPUT poBody    AS JsonObject ):

        EnsureFacLijnExists( piFacnr, piLijnnr ).

        EMPTY TEMP-TABLE ttFacLed.

        DO TRANSACTION:
            FIND FIRST fac_led EXCLUSIVE-LOCK
                WHERE fac_led.facnr   EQ piFacnr
                  AND fac_led.lijnnr  EQ piLijnnr
                  AND fac_led.groepnr EQ piGroepnr
                  AND fac_led.led_lijn EQ piLedLijn NO-ERROR.
            IF NOT AVAILABLE fac_led THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Fac_led &1/&2/&3/&4 not found":u, piFacnr, piLijnnr, piGroepnr, piLedLijn), 404).

            ApplyFields( INPUT poBody, BUFFER fac_led ).

            CREATE ttFacLed.
            CopyToTt( BUFFER fac_led, BUFFER ttFacLed ).
        END.

        RETURN TEMP-TABLE ttFacLed:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a fac_led by facnr+lijnnr+groepnr+ledLijn.
        Errors : AppError code 404 - the parent facnr/lijnnr doesn't exist,
                 or the groepnr+ledLijn doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteFacLed(
        INPUT piFacnr   AS INTEGER,
        INPUT piLijnnr  AS INTEGER,
        INPUT piGroepnr AS INTEGER,
        INPUT piLedLijn AS INTEGER ):

        EnsureFacLijnExists( piFacnr, piLijnnr ).

        DO TRANSACTION:
            FIND FIRST fac_led EXCLUSIVE-LOCK
                WHERE fac_led.facnr   EQ piFacnr
                  AND fac_led.lijnnr  EQ piLijnnr
                  AND fac_led.groepnr EQ piGroepnr
                  AND fac_led.led_lijn EQ piLedLijn NO-ERROR.
            IF NOT AVAILABLE fac_led THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Fac_led &1/&2/&3/&4 not found":u, piFacnr, piLijnnr, piGroepnr, piLedLijn), 404).

            DELETE fac_led.
        END.

    END METHOD.

END CLASS.
