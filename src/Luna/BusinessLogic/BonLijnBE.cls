/*------------------------------------------------------------------------
    File        : BonLijnBE.cls
    Purpose     : Business Entity for the "bonlijn" (order line) table -
                  owns full CRUD access for a curated core subset of fields
                  (identification, article, quantities, pricing, status).
                  `bonlijn` is a child of `bon` (linked via bonnr) - every
                  method here always operates within the scope of a single
                  bonnr. The `bonlijn` table has ~90 fields in total; only
                  the subset below is exposed via the API for now
                  (production/LED/voorproductie/lock/offerte-link fields
                  are explicitly out of scope).
    Field map (JSON key -> bonlijn column):
                  bonnr        -> bonnr        (PK, from parent path segment, immutable)
                  lijnnr       -> lijnnr       (PK, server-generated on create, immutable)
                  stempel      -> stempel      (raw code, no label mapping)
                  artnr        -> artnr
                  omschrijving -> omschr
                  aantal       -> aantal
                  teLeveren    -> te-leveren
                  besteld      -> besteld
                  vprijs       -> vprijs
                  aprijs       -> aprijs
                  korting      -> korting
                  btwKode      -> btw-kode
                  bedrag       -> bedrag
                  levDatum     -> lev-dat
                  bestelDatum  -> bestel-dat
                  klnr         -> klnr
                  groepnr      -> groepnr
                  subgroepnr   -> subgroepnr
                  hold         -> hold
                  opm          -> opm
                  subtotaal    -> subtotaal
                  kolomtitel   -> kolomtitel
                  infolijn     -> infolijn
    Syntax      : Called from Luna.Web.BonHandler (GET/POST/PUT/DELETE
                  /web/bon/{bonnr}/lijn and /web/bon/{bonnr}/lijn/{lijnnr})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. Callers
                  are expected to have already validated that the parent
                  bon (bonnr) exists - see EnsureBonExists. `lijnnr` is
                  assigned server-side (last lijnnr for that bonnr + 1, via
                  the bonlijn-x1 index) inside the same transaction as the
                  CREATE, mirroring how BonBE:CreateBon generates bonnr -
                  it is never read from the request body. No cascade on
                  delete - bonlijn has no child tables in this scope.
    Author(s)   : Devin
    Created     : 2026-08-13
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.BonLijnBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results (get/create/update) the WebHandler unwraps the
       first (and only) entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttBonLijn NO-UNDO SERIALIZE-NAME "items":u
        FIELD bonnr        AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD lijnnr       AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD stempel      AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD aantal       AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD teLeveren    AS DECIMAL   SERIALIZE-NAME "teLeveren":u
        FIELD besteld      AS DECIMAL   SERIALIZE-NAME "besteld":u
        FIELD vprijs       AS DECIMAL   SERIALIZE-NAME "vprijs":u
        FIELD aprijs       AS DECIMAL   SERIALIZE-NAME "aprijs":u
        FIELD korting      AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD btwKode      AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag       AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD levDatum     AS DATE      SERIALIZE-NAME "levDatum":u
        FIELD bestelDatum  AS DATE      SERIALIZE-NAME "bestelDatum":u
        FIELD klnr         AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD groepnr      AS INTEGER   SERIALIZE-NAME "groepnr":u
        FIELD subgroepnr   AS INTEGER   SERIALIZE-NAME "subgroepnr":u
        FIELD hold         AS LOGICAL   SERIALIZE-NAME "hold":u
        FIELD opm          AS CHARACTER SERIALIZE-NAME "opm":u
        FIELD subtotaal    AS LOGICAL   SERIALIZE-NAME "subtotaal":u
        FIELD kolomtitel   AS LOGICAL   SERIALIZE-NAME "kolomtitel":u
        FIELD infolijn     AS LOGICAL   SERIALIZE-NAME "infolijn":u
        INDEX idx-lijnnr IS PRIMARY bonnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Throws AppError 404 if the parent bon (bonnr) doesn't
                 exist. Called at the start of every method here so bonlijn
                 CRUD never silently operates on/under a non-existent
                 order.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EnsureBonExists( INPUT piBonnr AS INTEGER ):

        FIND FIRST bon NO-LOCK
            WHERE bon.bonnr EQ piBonnr NO-ERROR.

        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from a `bonlijn` buffer
                 into a ttBonLijn row, for use by every read/write method
                 below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbBonLijn FOR bonlijn, BUFFER pbTt FOR ttBonLijn ):

        ASSIGN
            pbTt.bonnr        = pbBonLijn.bonnr
            pbTt.lijnnr       = pbBonLijn.lijnnr
            pbTt.stempel      = pbBonLijn.stempel
            pbTt.artnr        = pbBonLijn.artnr
            pbTt.omschrijving = pbBonLijn.omschr
            pbTt.aantal       = pbBonLijn.aantal
            pbTt.teLeveren    = pbBonLijn.te-leveren
            pbTt.besteld      = pbBonLijn.besteld
            pbTt.vprijs       = pbBonLijn.vprijs
            pbTt.aprijs       = pbBonLijn.aprijs
            pbTt.korting      = pbBonLijn.korting
            pbTt.btwKode      = pbBonLijn.btw-kode
            pbTt.bedrag       = pbBonLijn.bedrag
            pbTt.levDatum     = pbBonLijn.lev-dat
            pbTt.bestelDatum  = pbBonLijn.bestel-dat
            pbTt.klnr         = pbBonLijn.klnr
            pbTt.groepnr      = pbBonLijn.groepnr
            pbTt.subgroepnr   = pbBonLijn.subgroepnr
            pbTt.hold         = pbBonLijn.hold
            pbTt.opm          = pbBonLijn.opm
            pbTt.subtotaal    = pbBonLijn.subtotaal
            pbTt.kolomtitel   = pbBonLijn.kolomtitel
            pbTt.infolijn     = pbBonLijn.infolijn
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `bonlijn` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `bonnr`/`lijnnr` are never read from the body at all - they
                 are set once on create (from the parent path segment and
                 server-generated respectively) and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbBonLijn FOR bonlijn ):

        IF poBody:Has("stempel":u)      THEN pbBonLijn.stempel     = poBody:GetCharacter("stempel":u).
        IF poBody:Has("artnr":u)        THEN pbBonLijn.artnr       = poBody:GetCharacter("artnr":u).
        IF poBody:Has("omschrijving":u) THEN pbBonLijn.omschr      = poBody:GetCharacter("omschrijving":u).
        IF poBody:Has("aantal":u)       THEN pbBonLijn.aantal      = poBody:GetDecimal("aantal":u).
        IF poBody:Has("teLeveren":u)    THEN pbBonLijn.te-leveren  = poBody:GetDecimal("teLeveren":u).
        IF poBody:Has("besteld":u)      THEN pbBonLijn.besteld     = poBody:GetDecimal("besteld":u).
        IF poBody:Has("vprijs":u)       THEN pbBonLijn.vprijs      = poBody:GetDecimal("vprijs":u).
        IF poBody:Has("aprijs":u)       THEN pbBonLijn.aprijs      = poBody:GetDecimal("aprijs":u).
        IF poBody:Has("korting":u)      THEN pbBonLijn.korting     = poBody:GetDecimal("korting":u).
        IF poBody:Has("btwKode":u)      THEN pbBonLijn.btw-kode    = poBody:GetCharacter("btwKode":u).
        IF poBody:Has("bedrag":u)       THEN pbBonLijn.bedrag      = poBody:GetDecimal("bedrag":u).
        IF poBody:Has("levDatum":u)     THEN pbBonLijn.lev-dat     = poBody:GetDate("levDatum":u).
        IF poBody:Has("bestelDatum":u)  THEN pbBonLijn.bestel-dat  = poBody:GetDate("bestelDatum":u).
        IF poBody:Has("klnr":u)         THEN pbBonLijn.klnr        = poBody:GetInteger("klnr":u).
        IF poBody:Has("groepnr":u)      THEN pbBonLijn.groepnr     = poBody:GetInteger("groepnr":u).
        IF poBody:Has("subgroepnr":u)   THEN pbBonLijn.subgroepnr  = poBody:GetInteger("subgroepnr":u).
        IF poBody:Has("hold":u)         THEN pbBonLijn.hold        = poBody:GetLogical("hold":u).
        IF poBody:Has("opm":u)          THEN pbBonLijn.opm         = poBody:GetCharacter("opm":u).
        IF poBody:Has("subtotaal":u)    THEN pbBonLijn.subtotaal   = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u)   THEN pbBonLijn.kolomtitel  = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)     THEN pbBonLijn.infolijn    = poBody:GetLogical("infolijn":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every bonlijn row for the given bonnr, ordered by
                 lijnnr.
        Notes  : NO-LOCK read-only. Uses the bonlijn-x1 (unique) index. No
                 paging - a bon typically has a bounded number of lines.
        Errors : AppError code 404 - the parent bonnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetBonLijnen( INPUT piBonnr AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLijn.

        FOR EACH bonlijn NO-LOCK
            WHERE bonlijn.bonnr EQ piBonnr
            BY bonlijn.lijnnr:

            CREATE ttBonLijn.
            CopyToTt( BUFFER bonlijn, BUFFER ttBonLijn ).
        END.

        RETURN TEMP-TABLE ttBonLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single bonlijn by bonnr+lijnnr, or an empty
                 ttBonLijn if it doesn't exist (the WebHandler turns that
                 into a 404).
        Errors : AppError code 404 - the parent bonnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetBonLijn( INPUT piBonnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLijn.

        FIND FIRST bonlijn NO-LOCK
            WHERE bonlijn.bonnr EQ piBonnr
              AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.

        IF AVAILABLE bonlijn THEN
        DO:
            CREATE ttBonLijn.
            CopyToTt( BUFFER bonlijn, BUFFER ttBonLijn ).
        END.

        RETURN TEMP-TABLE ttBonLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new bonlijn under the given bonnr. `lijnnr` is
                 computed server-side as (last lijnnr for this bonnr, via
                 the bonlijn-x1 index) + 1, held under the same
                 EXCLUSIVE-LOCK/transaction as the CREATE so there is no
                 race between the FIND LAST and the CREATE. `lijnnr` sent
                 in the request body (if any) is ignored - it is never read
                 from poBody.
        Errors : AppError code 404 - the parent bonnr doesn't exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBonLijn( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewLijnnr AS INTEGER NO-UNDO.

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLijn.

        DO TRANSACTION:
            FIND LAST bonlijn USE-INDEX bonlijn-x1 EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr EQ piBonnr NO-ERROR.

            iNewLijnnr = (IF AVAILABLE bonlijn THEN bonlijn.lijnnr ELSE 0) + 1.

            CREATE bonlijn.
            ASSIGN
                bonlijn.bonnr  = piBonnr
                bonlijn.lijnnr = iNewLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER bonlijn ).

            CREATE ttBonLijn.
            CopyToTt( BUFFER bonlijn, BUFFER ttBonLijn ).
        END.

        RETURN TEMP-TABLE ttBonLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing bonlijn. Only fields present in the
                 JSON body are changed (partial update); `bonnr`/`lijnnr`
                 are immutable and never read from the body.
        Errors : AppError code 404 - the parent bonnr doesn't exist, or the
                 lijnnr doesn't exist under it.
                 AppError code 409 - the bonlijn has stempel "D" (geleverd).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateBonLijn(
        INPUT piBonnr  AS INTEGER,
        INPUT piLijnnr AS INTEGER,
        INPUT poBody   AS JsonObject ):

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLijn.

        DO TRANSACTION:
            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr EQ piBonnr
                  AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piLijnnr), 404).

            IF bonlijn.stempel EQ "D":u THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 has stempel 'D' (geleverd) and cannot be updated":u,
                        piBonnr, piLijnnr), 409).

            ApplyFields( INPUT poBody, BUFFER bonlijn ).

            CREATE ttBonLijn.
            CopyToTt( BUFFER bonlijn, BUFFER ttBonLijn ).
        END.

        RETURN TEMP-TABLE ttBonLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a bonlijn by bonnr+lijnnr. No cascade - bonlijn
                 has no child tables in this scope.
        Errors : AppError code 404 - the parent bonnr doesn't exist, or the
                 lijnnr doesn't exist under it.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteBonLijn( INPUT piBonnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        EnsureBonExists( piBonnr ).

        DO TRANSACTION:
            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr EQ piBonnr
                  AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piLijnnr), 404).

            DELETE bonlijn.
        END.

    END METHOD.

END CLASS.
