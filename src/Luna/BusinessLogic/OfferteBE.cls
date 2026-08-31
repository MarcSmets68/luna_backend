/*------------------------------------------------------------------------
    File        : OfferteBE.cls
    Purpose     : Business Entity for the "offerte" (quote) table - owns full
                  CRUD access for a curated core subset of fields
                  (identification, customer, amounts, status). The `offerte`
                  table has ~90 fields in total; only the subset below is
                  exposed via the API for now.
    Field map (JSON key -> offerte column):
                  offnr            -> offnr             (PK, required on create, immutable)
                  versie           -> versie             (PK, required on create, immutable)
                  datum            -> datum
                  klnr             -> klnr
                  naam             -> naam
                  adres            -> adres
                  postnr           -> postnr
                  stad             -> stad
                  munt             -> munt
                  bedrag           -> b-bedrag           (bruto/gross total)
                  btw              -> tot-btw
                  offgroep         -> offgroep
                  soort            -> soort
                  passief          -> passief
                  verloren         -> verloren
                  verkocht         -> verkocht
                  verkoopkans      -> verkoopkans
                  uRef             -> u-ref
                  besteldatum      -> besteldatum
                  verkochtdatum    -> verkochtdatum
                  opm              -> opm
    Notes       : Every `offerte` row (one per offnr+versie) is returned as
                  its own item - this does not dedupe to "latest versie per
                  offnr". Callers that only want the current revision of
                  each quote should filter/group on the client for now.
                  Deleting an offerte cascades to its `offlijn` rows (see
                  DeleteOfferte) so no orphan lines are left behind - line
                  CRUD itself lives in Luna.BusinessLogic.OfflijnBE.
    Syntax      : Called from Luna.Web.OfferteHandler (GET/POST/PUT/DELETE
                  /web/offerte and /web/offerte/{offnr}/{versie})
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes.
    Author(s)   : Devin
    Created     : 2026-08-11
    Updated     : 2026-08-19 - added offnr prefix filter to GetOffertes(),
                  mirroring Luna.BusinessLogic.BestelorderBE:GetBestelorders's
                  pcOrdnr filter.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OfferteBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. For
       single-record results the WebHandler unwraps the first (and only)
       entry of "items" into a plain JSON object. */
    DEFINE TEMP-TABLE ttOfferte NO-UNDO SERIALIZE-NAME "items":u
        FIELD offnr         AS INTEGER   SERIALIZE-NAME "offnr":u
        FIELD versie        AS INTEGER   SERIALIZE-NAME "versie":u
        FIELD datum         AS DATE      SERIALIZE-NAME "datum":u
        FIELD klnr          AS INTEGER   SERIALIZE-NAME "klnr":u
        FIELD naam          AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD adres         AS CHARACTER SERIALIZE-NAME "adres":u
        FIELD postnr        AS CHARACTER SERIALIZE-NAME "postnr":u
        FIELD stad          AS CHARACTER SERIALIZE-NAME "stad":u
        FIELD munt          AS CHARACTER SERIALIZE-NAME "munt":u
        FIELD bedrag        AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD btw           AS DECIMAL   SERIALIZE-NAME "btw":u
        FIELD offgroep      AS CHARACTER SERIALIZE-NAME "offgroep":u
        FIELD soort         AS CHARACTER SERIALIZE-NAME "soort":u
        FIELD passief       AS LOGICAL   SERIALIZE-NAME "passief":u
        FIELD verloren      AS LOGICAL   SERIALIZE-NAME "verloren":u
        FIELD verkocht      AS LOGICAL   SERIALIZE-NAME "verkocht":u
        FIELD verkoopkans   AS INTEGER   SERIALIZE-NAME "verkoopkans":u
        FIELD uRef          AS CHARACTER SERIALIZE-NAME "uRef":u
        FIELD besteldatum   AS DATE      SERIALIZE-NAME "besteldatum":u
        FIELD verkochtdatum AS DATE      SERIALIZE-NAME "verkochtdatum":u
        FIELD opm           AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-offnr IS PRIMARY offnr DESCENDING versie DESCENDING.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from an `offerte` buffer
                 into a ttOfferte row, for use by every read method below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbOfferte FOR offerte, BUFFER pbTt FOR ttOfferte ):

        ASSIGN
            pbTt.offnr         = pbOfferte.offnr
            pbTt.versie        = pbOfferte.versie
            pbTt.datum         = pbOfferte.datum
            pbTt.klnr          = pbOfferte.klnr
            pbTt.naam          = pbOfferte.naam
            pbTt.adres         = pbOfferte.adres
            pbTt.postnr        = pbOfferte.postnr
            pbTt.stad          = pbOfferte.stad
            pbTt.munt          = pbOfferte.munt
            pbTt.bedrag        = pbOfferte.b-bedrag
            pbTt.btw           = pbOfferte.tot-btw
            pbTt.offgroep      = pbOfferte.offgroep
            pbTt.soort         = pbOfferte.soort
            pbTt.passief       = pbOfferte.passief
            pbTt.verloren      = pbOfferte.verloren
            pbTt.verkocht      = pbOfferte.verkocht
            pbTt.verkoopkans   = pbOfferte.verkoopkans
            pbTt.uRef          = pbOfferte.u-ref
            pbTt.besteldatum   = pbOfferte.besteldatum
            pbTt.verkochtdatum = pbOfferte.verkochtdatum
            pbTt.opm           = pbOfferte.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto the
                 given `offerte` buffer. Fields absent from the body are left
                 untouched, so this also works for partial updates. `offnr`/
                 `versie` are never touched here - they are set once on
                 create and are immutable.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbOfferte FOR offerte ):

        IF poBody:Has("datum":u)         THEN pbOfferte.datum         = poBody:GetDate("datum":u).
        IF poBody:Has("klnr":u)          THEN pbOfferte.klnr          = poBody:GetInteger("klnr":u).
        IF poBody:Has("naam":u)          THEN pbOfferte.naam          = poBody:GetCharacter("naam":u).
        IF poBody:Has("adres":u)         THEN pbOfferte.adres         = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)        THEN pbOfferte.postnr        = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)          THEN pbOfferte.stad          = poBody:GetCharacter("stad":u).
        IF poBody:Has("munt":u)          THEN pbOfferte.munt          = poBody:GetCharacter("munt":u).
        IF poBody:Has("bedrag":u)        THEN pbOfferte.b-bedrag      = poBody:GetDecimal("bedrag":u).
        IF poBody:Has("btw":u)           THEN pbOfferte.tot-btw       = poBody:GetDecimal("btw":u).
        IF poBody:Has("offgroep":u)      THEN pbOfferte.offgroep      = poBody:GetCharacter("offgroep":u).
        IF poBody:Has("soort":u)         THEN pbOfferte.soort         = poBody:GetCharacter("soort":u).
        IF poBody:Has("passief":u)       THEN pbOfferte.passief       = poBody:GetLogical("passief":u).
        IF poBody:Has("verloren":u)      THEN pbOfferte.verloren      = poBody:GetLogical("verloren":u).
        IF poBody:Has("verkocht":u)      THEN pbOfferte.verkocht      = poBody:GetLogical("verkocht":u).
        IF poBody:Has("verkoopkans":u)   THEN pbOfferte.verkoopkans   = poBody:GetInteger("verkoopkans":u).
        IF poBody:Has("uRef":u)          THEN pbOfferte.u-ref         = poBody:GetCharacter("uRef":u).
        IF poBody:Has("besteldatum":u)   THEN pbOfferte.besteldatum   = poBody:GetDate("besteldatum":u).
        IF poBody:Has("verkochtdatum":u) THEN pbOfferte.verkochtdatum = poBody:GetDate("verkochtdatum":u).
        IF poBody:Has("opm":u)           THEN pbOfferte.opm           = poBody:GetCharacter("opm":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a page of offerte rows (newest offnr/versie first),
                 optionally filtered by klnr (exact), offgroep (exact), offnr
                 (prefix match on the string form) and naam (substring match).
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200).
                 Same approach as Luna.BusinessLogic.KlantBE:GetKlanten() - this
                 deliberately does NOT compute an exact total count, instead it
                 stops scanning as soon as it has one extra row beyond the
                 requested page and reports that via plHasMore. `klnr` uses the
                 existing offerte-x3 index and `offgroep` uses offerte-x2; a
                 naam-only filter scans every candidate row and should be
                 combined with `klnr`/`offgroep` where possible. `offnr` is a
                 prefix match on STRING(offerte.offnr), mirroring the pcOrdnr
                 filter in Luna.BusinessLogic.BestelorderBE:GetBestelorders() -
                 an offnr filter still returns every matching versie row for
                 that quote number (this method does not dedupe to "latest
                 versie per offnr", see the class header note).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOffertes(
        INPUT  piKlnr     AS INTEGER,
        INPUT  pcOffgroep AS CHARACTER,
        INPUT  pcOffnr    AS CHARACTER,
        INPUT  pcNaam     AS CHARACTER,
        INPUT  piPage     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        OUTPUT plHasMore  AS LOGICAL ):

        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO.
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttOfferte.

        ASSIGN
            pcOffgroep = TRIM(pcOffgroep)
            pcOffnr    = TRIM(pcOffnr)
            pcNaam     = UPPER(TRIM(pcNaam))
            iSkip      = (piPage - 1) * piPageSize
            iSeen      = 0
            iTaken     = 0
            plHasMore  = FALSE
            .

        FOR EACH offerte NO-LOCK
            WHERE (piKlnr LE 0 OR offerte.klnr EQ piKlnr)
              AND (pcOffgroep EQ "":u OR offerte.offgroep EQ pcOffgroep)
              AND (pcOffnr EQ "":u OR STRING(offerte.offnr) BEGINS pcOffnr)
              AND (pcNaam EQ "":u OR INDEX(UPPER(offerte.naam), pcNaam) GT 0)
            BY offerte.offnr DESCENDING BY offerte.versie DESCENDING:

            iSeen = iSeen + 1.

            IF iSeen LE iSkip THEN NEXT.

            IF iTaken GE piPageSize THEN
            DO:
                plHasMore = TRUE.
                LEAVE.
            END.

            CREATE ttOfferte.
            CopyToTt( BUFFER offerte, BUFFER ttOfferte ).
            iTaken = iTaken + 1.
        END.

        RETURN TEMP-TABLE ttOfferte:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single offerte by offnr + versie, or an empty
                 ttOfferte if it doesn't exist (the WebHandler turns that
                 into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOfferte( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        EMPTY TEMP-TABLE ttOfferte.

        FIND FIRST offerte NO-LOCK
            WHERE offerte.offnr EQ piOffnr
              AND offerte.versie EQ piVersie NO-ERROR.

        IF AVAILABLE offerte THEN
        DO:
            CREATE ttOfferte.
            CopyToTt( BUFFER offerte, BUFFER ttOfferte ).
        END.

        RETURN TEMP-TABLE ttOfferte:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new offerte. Two modes, mirroring
                 Luna.BusinessLogic.BonBE:CreateBon's `bonnr` auto-allocation
                 pattern:
                 - Both `offnr` and `versie` omitted from the body: server
                   auto-allocates `offnr` = (last offerte.offnr, via the
                   offerte-x1 (PRIMARY) index) + 1 and `versie` = 1, under the
                   same EXCLUSIVE-LOCK/transaction as the CREATE so there is
                   no race between the FIND LAST and the CREATE.
                 - Both `offnr` and `versie` present in the body: today's
                   explicit path - both must be positive integers and the
                   combination must not already exist.
                 - Exactly one of the two present: 400 (ambiguous request).
        Errors : AppError code 400 - exactly one of offnr/versie provided, or
                 (explicit mode) offnr/versie not a positive integer.
                 AppError code 409 - (explicit mode) offnr+versie already
                 exists.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateOfferte( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iOffnr    AS INTEGER NO-UNDO.
        DEFINE VARIABLE iVersie   AS INTEGER NO-UNDO.
        DEFINE VARIABLE lHasOffnr AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lHasVersie AS LOGICAL NO-UNDO.

        EMPTY TEMP-TABLE ttOfferte.

        lHasOffnr  = poBody:Has("offnr":u).
        lHasVersie = poBody:Has("versie":u).

        IF lHasOffnr NE lHasVersie THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                "offnr and versie must both be provided, or both omitted for auto-allocation":u, 400).

        IF NOT lHasOffnr AND NOT lHasVersie THEN
        DO:
            /* Auto-allocate mode. */
            DO TRANSACTION:
                FIND LAST offerte USE-INDEX offerte-x1 EXCLUSIVE-LOCK NO-ERROR.

                iOffnr  = (IF AVAILABLE offerte THEN offerte.offnr ELSE 0) + 1.
                iVersie = 1.

                CREATE offerte.
                ASSIGN
                    offerte.offnr  = iOffnr
                    offerte.versie = iVersie
                    .

                ApplyFields( INPUT poBody, BUFFER offerte ).

                CREATE ttOfferte.
                CopyToTt( BUFFER offerte, BUFFER ttOfferte ).
            END.

            RETURN TEMP-TABLE ttOfferte:HANDLE.
        END.

        /* Explicit mode - unchanged from before. */
        iOffnr = poBody:GetInteger("offnr":u) NO-ERROR.
        IF iOffnr EQ ? OR iOffnr LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("offnr must be a positive integer":u, 400).

        iVersie = poBody:GetInteger("versie":u) NO-ERROR.
        IF iVersie EQ ? OR iVersie LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("versie must be a positive integer":u, 400).

        DO TRANSACTION:
            FIND FIRST offerte EXCLUSIVE-LOCK
                WHERE offerte.offnr EQ iOffnr
                  AND offerte.versie EQ iVersie NO-ERROR.
            IF AVAILABLE offerte THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offerte &1/&2 already exists":u, iOffnr, iVersie), 409).

            CREATE offerte.
            ASSIGN
                offerte.offnr  = iOffnr
                offerte.versie = iVersie
                .

            ApplyFields( INPUT poBody, BUFFER offerte ).

            CREATE ttOfferte.
            CopyToTt( BUFFER offerte, BUFFER ttOfferte ).
        END.

        RETURN TEMP-TABLE ttOfferte:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing offerte. Only fields present in the JSON
                 body are changed (partial update); `offnr`/`versie` are
                 immutable.
        Notes  : "verloren" auto-clear business rule - if the request body is
                 non-empty (>= 1 key) AND the pre-update `verloren` was TRUE
                 AND the body itself did NOT include a "verloren" key, then
                 `verloren` is force-cleared to FALSE after applying the rest
                 of the body. An explicit "verloren" key in the body always
                 wins over this auto-clear. This is server-side business
                 logic - it applies to every caller, not just the frontend.
        Errors : AppError code 404 - offnr/versie not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateOfferte( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE lWasVerloren AS LOGICAL   NO-UNDO.
        DEFINE VARIABLE cBodyNames   AS CHARACTER EXTENT NO-UNDO.

        EMPTY TEMP-TABLE ttOfferte.

        DO TRANSACTION:
            FIND FIRST offerte EXCLUSIVE-LOCK
                WHERE offerte.offnr EQ piOffnr
                  AND offerte.versie EQ piVersie NO-ERROR.
            IF NOT AVAILABLE offerte THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offerte &1/&2 not found":u, piOffnr, piVersie), 404).

            lWasVerloren = offerte.verloren.

            ApplyFields( INPUT poBody, BUFFER offerte ).

            cBodyNames = poBody:GetNames().

            IF EXTENT(cBodyNames) GT 0
               AND lWasVerloren
               AND NOT poBody:Has("verloren":u) THEN
                offerte.verloren = FALSE.

            CREATE ttOfferte.
            CopyToTt( BUFFER offerte, BUFFER ttOfferte ).
        END.

        RETURN TEMP-TABLE ttOfferte:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes an offerte by offnr+versie, cascading to every
                 `offlijn` row for that offnr+versie so no orphan lines are
                 left behind.
        Errors : AppError code 404 - offnr/versie not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteOfferte( INPUT piOffnr AS INTEGER, INPUT piVersie AS INTEGER ):

        DO TRANSACTION:
            FIND FIRST offerte EXCLUSIVE-LOCK
                WHERE offerte.offnr EQ piOffnr
                  AND offerte.versie EQ piVersie NO-ERROR.
            IF NOT AVAILABLE offerte THEN
                UNDO, THROW NEW Progress.Lang.AppError(
                    SUBSTITUTE("Offerte &1/&2 not found":u, piOffnr, piVersie), 404).

            FOR EACH offlijn EXCLUSIVE-LOCK
                WHERE offlijn.offnr EQ piOffnr
                  AND offlijn.versie EQ piVersie:
                DELETE offlijn.
            END.

            DELETE offerte.
        END.

    END METHOD.

END CLASS.
