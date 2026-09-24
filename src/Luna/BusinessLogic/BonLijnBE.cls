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
                  gereserv           -> gereserv           (read-only, computed by reservation logic)
                  effectiefGereserv  -> effectief-gereserv  (read-only, computed by reservation logic)
                  swEffectief        -> swEffectief         (read-only, drives under-reservation indicator)
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
                  Non-item line guards: a bonlijn is either a normal (item)
                  line or exactly one of subtotaal/kolomtitel/infolijn -
                  never more than one at a time. This is enforced on create
                  (against the request body) and on update (against the
                  merged state of the existing row + body), via the shared
                  HasConflictingFlags helper. A subtotaal line additionally
                  requires at least one preceding normal line under the
                  same bonnr to sum - checked on create only. Reads
                  (GetBonLijn/GetBonLijnen) are never guarded, so
                  pre-existing rows that predate this validation stay
                  readable even if they violate it.
    Author(s)   : Devin
    Created     : 2026-08-13
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.BonBE.
USING Luna.BusinessLogic.BonHerstelBE.

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
        FIELD gereserv          AS DECIMAL SERIALIZE-NAME "gereserv":u
        FIELD effectiefGereserv AS DECIMAL SERIALIZE-NAME "effectiefGereserv":u
        FIELD swEffectief       AS LOGICAL SERIALIZE-NAME "swEffectief":u
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
            pbTt.gereserv          = pbBonLijn.gereserv
            pbTt.effectiefGereserv = pbBonLijn.effectief-gereserv
            pbTt.swEffectief       = pbBonLijn.swEffectief
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto
                 the given `bonlijn` buffer. Fields absent from the body are
                 left untouched, so this also works for partial updates.
                 `bonnr`/`lijnnr` are never read from the body at all - they
                 are set once on create (from the parent path segment and
                 server-generated respectively) and are immutable. This is
                 the field set exposed via the public POST/PUT
                 /web/bon/{bonnr}/lijn JSON contract - do NOT add fields
                 here that should only be settable internally (see
                 ApplyFieldsExtended for those, used only by
                 CreateBonLijnInternal's internal-only callers).
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
        Purpose: Applies the extra fields that are ONLY settable via the
                 internal CreateBonLijnInternal path (Iteratie D - Offerte->
                 Order conversie) - offnr/versie/olijnnr (offerte-link),
                 swLed/swSikta/montage/ledmontage/circuit/recupel/meer_min/
                 off_aantal/swStdPrijs/uitverkoop/SiktaKleurKodes. These are
                 deliberately NOT part of ApplyFields/the public POST/PUT
                 /web/bon/{bonnr}/lijn JSON contract - a request body sent
                 to that public endpoint containing any of these keys has
                 them silently ignored (proven by
                 bruno/Bon/CreateIgnoresInternalFields.bru).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFieldsExtended( INPUT poBody AS JsonObject, BUFFER pbBonLijn FOR bonlijn ):

        IF poBody:Has("offnr":u)          THEN pbBonLijn.offnr          = poBody:GetInteger("offnr":u).
        IF poBody:Has("versie":u)         THEN pbBonLijn.versie         = poBody:GetInteger("versie":u).
        IF poBody:Has("olijnnr":u)        THEN pbBonLijn.olijnnr        = poBody:GetInteger("olijnnr":u).
        IF poBody:Has("swLed":u)          THEN pbBonLijn.swLed          = poBody:GetLogical("swLed":u).
        IF poBody:Has("swSikta":u)        THEN pbBonLijn.swSikta        = poBody:GetLogical("swSikta":u).
        IF poBody:Has("montage":u)        THEN pbBonLijn.montage        = poBody:GetLogical("montage":u).
        IF poBody:Has("ledmontage":u)     THEN pbBonLijn.ledmontage     = poBody:GetLogical("ledmontage":u).
        IF poBody:Has("circuit":u)        THEN pbBonLijn.circuit        = poBody:GetInteger("circuit":u).
        IF poBody:Has("recupel":u)        THEN pbBonLijn.recupel        = poBody:GetDecimal("recupel":u).
        IF poBody:Has("meer_min":u)       THEN pbBonLijn.meer_min       = poBody:GetDecimal("meer_min":u).
        IF poBody:Has("off_aantal":u)     THEN pbBonLijn.off_aantal     = poBody:GetDecimal("off_aantal":u).
        IF poBody:Has("swStdPrijs":u)     THEN pbBonLijn.swStdPrijs     = poBody:GetLogical("swStdPrijs":u).
        IF poBody:Has("uitverkoop":u)     THEN pbBonLijn.uitverkoop     = poBody:GetLogical("uitverkoop":u).
        IF poBody:Has("SiktaKleurKodes":u) THEN pbBonLijn.SiktaKleurKodes = poBody:GetCharacter("SiktaKleurKodes":u).
        /* Iteratie D addition beyond the design doc's literal field list -
           see Luna.BusinessLogic.OfferteConversieBE class header, decision
           5: bonlijn.gereserv is otherwise read-only/computed (by the
           Iteratie C auto-reservation hook), but the offerte conversion
           needs to set it directly for kolomtitel/infolijn lines (which
           never go through that hook). */
        IF poBody:Has("gereserv":u)       THEN pbBonLijn.gereserv       = poBody:GetDecimal("gereserv":u).

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
        Purpose: Returns TRUE if more than one of subtotaal/kolomtitel/
                 infolijn is set. A bonlijn is either a normal (item) line
                 or exactly one of these three non-item line types - never
                 more than one at a time.
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
        Purpose: Creates a new bonlijn under the given bonnr via the public
                 POST /web/bon/{bonnr}/lijn contract. Thin wrapper around
                 CreateBonLijnInternal with piExplicitLijnnr = 0 (server
                 auto-allocates lijnnr as (last lijnnr for this bonnr) + 1 -
                 unchanged behaviour from before this method was split out).
                 `lijnnr` sent in the request body (if any) is still ignored
                 - see CreateBonLijnInternal.
        Errors : AppError code 404 - the parent bonnr doesn't exist.
                 AppError code 400 - more than one of subtotaal/kolomtitel/
                 infolijn set, or a subtotaal line with no preceding
                 normal line to sum.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBonLijn( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        RETURN CreateBonLijnInternal( piBonnr, poBody, 0 ).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Internal (non-public-contract) create path shared by
                 CreateBonLijn (public, piExplicitLijnnr = 0 -> auto-
                 allocate, exactly as before this method existed) and
                 Luna.BusinessLogic.OfferteConversieBE (Iteratie D -
                 Offerte->Order conversie, piExplicitLijnnr > 0 -> use that
                 lijnnr verbatim, e.g. the 5000-per-line numbering scheme or
                 the "vorige doc-lijnnr + 100" deadline-lijn exception).
                 Accepts the extra offerte-conversion-only fields via
                 ApplyFieldsExtended (offnr/versie/olijnnr/swLed/swSikta/
                 montage/ledmontage/circuit/recupel/meer_min/off_aantal/
                 swStdPrijs/uitverkoop/SiktaKleurKodes) IN ADDITION TO the
                 normal ApplyFields set - poBody may contain both sets, but
                 only ApplyFieldsExtended's fields are new/internal-only.
                 Still shares HasConflictingFlags and the Iteratie C
                 automatic-reservation hook with the original CreateBonLijn
                 behaviour.
        Notes  : The "a subtotaal line needs at least one preceding normal
                 line to sum" guard is only enforced on the auto-allocate
                 path (piExplicitLijnnr = 0). It is deliberately skipped
                 when piExplicitLijnnr > 0: OfferteConversieBE's Pass 1
                 creates subtotaal bonlijn rows for a group BEFORE that
                 group's item lines physically exist as bonlijn rows (Pass
                 2 creates those afterwards) - by design, not a bug - so
                 the guard would incorrectly reject every subtotaal line
                 coming from the conversion. The internal caller is
                 trusted to only ever create a subtotaal line that
                 legitimately sums a to-be-created (or already created)
                 block.
        Errors : AppError code 404 - the parent bonnr doesn't exist.
                 AppError code 400 - more than one of subtotaal/kolomtitel/
                 infolijn set, or (piExplicitLijnnr = 0 only) a subtotaal
                 line with no preceding normal line to sum.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBonLijnInternal(
        INPUT piBonnr          AS INTEGER,
        INPUT poBody           AS JsonObject,
        INPUT piExplicitLijnnr AS INTEGER ):

        DEFINE VARIABLE iNewLijnnr  AS INTEGER NO-UNDO.
        DEFINE VARIABLE lSubtotaal  AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lKolomtitel AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lInfolijn   AS LOGICAL NO-UNDO.

        EnsureBonExists( piBonnr ).

        EMPTY TEMP-TABLE ttBonLijn.

        IF poBody:Has("subtotaal":u)  THEN lSubtotaal  = poBody:GetLogical("subtotaal":u).
        IF poBody:Has("kolomtitel":u) THEN lKolomtitel = poBody:GetLogical("kolomtitel":u).
        IF poBody:Has("infolijn":u)   THEN lInfolijn   = poBody:GetLogical("infolijn":u).

        IF HasConflictingFlags(lSubtotaal, lKolomtitel, lInfolijn) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "A line can be at most one of subtotaal/kolomtitel/infolijn":u, 400).

        DO TRANSACTION:
            IF piExplicitLijnnr GT 0 THEN
                iNewLijnnr = piExplicitLijnnr.
            ELSE
            DO:
                FIND LAST bonlijn USE-INDEX bonlijn-x1 EXCLUSIVE-LOCK
                    WHERE bonlijn.bonnr EQ piBonnr NO-ERROR.

                iNewLijnnr = (IF AVAILABLE bonlijn THEN bonlijn.lijnnr ELSE 0) + 1.

                IF lSubtotaal THEN
                DO:
                    IF NOT CAN-FIND(FIRST bonlijn
                        WHERE bonlijn.bonnr EQ piBonnr
                          AND bonlijn.lijnnr LT iNewLijnnr
                          AND bonlijn.subtotaal EQ FALSE
                          AND bonlijn.kolomtitel EQ FALSE
                          AND bonlijn.infolijn EQ FALSE) THEN
                        UNDO, THROW NEW Progress.Lang.AppError(
                            "Cannot create a subtotaal line with no preceding lines to sum":u, 400).
                END.
            END.

            IF lSubtotaal THEN
            DO:
                IF NOT CAN-FIND(FIRST bonlijn
                    WHERE bonlijn.bonnr EQ piBonnr
                      AND bonlijn.lijnnr LT iNewLijnnr
                      AND bonlijn.subtotaal EQ FALSE
                      AND bonlijn.kolomtitel EQ FALSE
                      AND bonlijn.infolijn EQ FALSE) THEN
                    UNDO, THROW NEW Progress.Lang.AppError(
                        "Cannot create a subtotaal line with no preceding lines to sum":u, 400).
            END.

            CREATE bonlijn.
            ASSIGN
                bonlijn.bonnr  = piBonnr
                bonlijn.lijnnr = iNewLijnnr
                .

            ApplyFields( INPUT poBody, BUFFER bonlijn ).

            /* Internal-only fields (Iteratie D) - gated on
               piExplicitLijnnr > 0 (the internal-caller path; the public
               CreateBonLijn wrapper always passes 0), NOT merely on
               whether poBody happens to contain these keys. This is what
               actually keeps the public POST/PUT /web/bon/{bonnr}/lijn
               contract from accepting offnr/versie/olijnnr/swLed/swSikta/
               montage/ledmontage/circuit/recupel/meer_min/off_aantal/
               swStdPrijs/uitverkoop/SiktaKleurKodes - see
               ApplyFieldsExtended header and
               bruno/Bon/CreateIgnoresInternalFields.bru. */
            IF piExplicitLijnnr GT 0 THEN
                ApplyFieldsExtended( INPUT poBody, BUFFER bonlijn ).

            /* Iteratie C - automatische voorraadreservering: reserves
               stock (and, for a BOM article, its artlijn components) for
               the newly created line. Runs inside this same transaction
               (no own DO TRANSACTION - see Luna.BusinessLogic.
               BonLijnAutoReserveringBE) and is called before the ttBonLijn
               snapshot copy below so bonlijn.gereserv (set by
               ReserveerBijCreate) is included in the response. The `bon`
               buffer used here was already populated (NO-LOCK) by
               EnsureBonExists above - reused as-is, no new lookup. */
            NEW Luna.BusinessLogic.BonLijnAutoReserveringBE():ReserveerBijCreate( BUFFER bonlijn, BUFFER bon ).

            /* bon-auto-reservering design doc §5 (Open Question 10) -
               today CheckAutoTransitionToInHerstelling only fired from
               the manual reservering endpoint, so a HERSTELLING order
               whose only line gets fully auto-reserved purely via this
               create path could never auto-transition to
               "IN HERSTELLING". Reuses the existing, already-tested
               method verbatim, still inside this same transaction, right
               after the auto-reserve hook above - no change to
               BonHerstelBE itself. Best-effort/silent, same as the
               manual-reserve path - observable only via a subsequent
               GET .../herstel. */
            IF bon.type EQ "HERSTELLING":u THEN
                NEW BonHerstelBE():CheckAutoTransitionToInHerstelling( piBonnr ).

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
                 AppError code 400 - the merged state (existing row + body)
                 would have more than one of subtotaal/kolomtitel/infolijn
                 set. This is checked unconditionally against the merged
                 state, so an update to a pre-existing row that already has
                 more than one flag set (from before this guard existed)
                 will now 400 even if the update body itself doesn't touch
                 those fields.
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

            IF HasConflictingFlags(bonlijn.subtotaal, bonlijn.kolomtitel, bonlijn.infolijn) THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    "A line can be at most one of subtotaal/kolomtitel/infolijn":u, 400).

            CREATE ttBonLijn.
            CopyToTt( BUFFER bonlijn, BUFFER ttBonLijn ).
        END.

        RETURN TEMP-TABLE ttBonLijn:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a bonlijn by bonnr+lijnnr. No cascade to other
                 tables beyond the reservation release below - bonlijn has
                 no OTHER child tables in this scope.
        Notes  : bon-auto-reservering design doc §6 - before the DELETE,
                 releases whatever reservation this line still holds
                 (artikel.besteld-kl AND artikel.gereserveerd, plus BOM
                 sub-component pbesteld-kl for a "gemengd" article) via
                 Luna.BusinessLogic.BonBE:ReleaseReservationForLijn (shared
                 with BonBE:DeleteBon and AnnuleerBon's release loop - no
                 new BOM-walk code here), and deletes the auto-reserve
                 step's bonlijn_productie rows for this line. No contract
                 change to DELETE /web/bon/{bonnr}/lijn/{lijnnr}'s
                 request/response shape - this is purely an added
                 internal effect.
        Errors : AppError code 404 - the parent bonnr doesn't exist, or the
                 lijnnr doesn't exist under it.
                 AppError code 409 - a productie sublijn with besteld <> 0
                 still exists for this line (unrelated pre-existing guard).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteBonLijn( INPUT piBonnr AS INTEGER, INPUT piLijnnr AS INTEGER ):

        DEFINE VARIABLE oBonBE AS BonBE NO-UNDO.

        EnsureBonExists( piBonnr ).

        IF CAN-FIND(FIRST bonlijn_productie
            WHERE bonlijn_productie.bonnr  EQ piBonnr
              AND bonlijn_productie.blijnnr EQ piLijnnr
              AND bonlijn_productie.besteld NE 0) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bonlijn &1/&2 has a productie sublijn with besteld <> 0 and cannot be deleted":u,
                    piBonnr, piLijnnr), 409).

        oBonBE = NEW BonBE().

        DO TRANSACTION:
            FIND FIRST bonlijn EXCLUSIVE-LOCK
                WHERE bonlijn.bonnr EQ piBonnr
                  AND bonlijn.lijnnr EQ piLijnnr NO-ERROR.
            IF NOT AVAILABLE bonlijn THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Bonlijn &1/&2 not found":u, piBonnr, piLijnnr), 404).

            /* `bon` is the default buffer already populated (NO-LOCK) by
               EnsureBonExists above for this bonnr - reused as-is. */
            oBonBE:ReleaseReservationForLijn( BUFFER bonlijn, BUFFER bon ).

            DELETE bonlijn.
        END.

    END METHOD.

END CLASS.

