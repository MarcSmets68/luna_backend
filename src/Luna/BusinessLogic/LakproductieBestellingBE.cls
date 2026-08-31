/*------------------------------------------------------------------------
    File        : LakproductieBestellingBE.cls
    Purpose     : Business Entity that creates a new purchase order
                  ("order" + its "ordlijn" lines) from a confirmed
                  Lakproduktie bestelling-preview (see
                  Luna.Web.LakproductieHandler / POST
                  /web/lakproduktie/bestelling and the frontend
                  BestellingPreviewDialog).
    Notes       : Deliberately a SEPARATE class from
                  Luna.BusinessLogic.BestelorderBE - that class is
                  intentionally read-only ("no Create/Update/Delete methods
                  exist on this class - that is intentional, not an
                  oversight", see its own header) so this workflow-specific
                  creation logic does not get bolted onto it.
    Field map (JSON key -> ordlijn column):
                  artnr        -> artnr
                  omschrijving -> omschr        (free text, not re-derived
                                                 from artikel - same
                                                 convention as
                                                 Luna.BusinessLogic.BonLijnBE)
                  aantal       -> aantal
                  bonnr        -> bonnr         (optional - klantorder link)
                  blijnnr      -> blijnnr       (optional - klantorder-lijn link)
                  volgnr       -> volgnr        (optional - only for lines
                                                 sourced from a
                                                 bonlijn_productie
                                                 production line)
    Business rule : Every line that carries a bonnr/blijnnr link back to a
                  customer order line increases that line's `besteld`
                  counter by the ordered aantal, so the Lakproduktie
                  overview (Luna.BusinessLogic.LakproductieBE) picks up the
                  new status on its next read:
                    - bonnr + blijnnr, no volgnr  -> bonlijn.besteld        (source "lopende-orders")
                    - bonnr + blijnnr + volgnr    -> bonlijn_productie.besteld (source "lopende-productielijnen")
                    - no bonnr                    -> no bonlijn/bonlijn_productie to update
                                                      (source "min-max-voorraad", pure stock replenishment)
                  Lines are NEVER matched/validated against the remaining
                  outstanding quantity here - the frontend preview already
                  proposes the outstanding balance as the default aantal
                  but lets the user freely edit it (confirmed with Marc),
                  so this class trusts the aantal it is given as long as it
                  is a positive number.
                  The new order header also copies `lever.btw-reg` (BTW-
                  regime) onto `order.btw-reg`, same as the other supplier
                  master fields (naam/adres/taal/land/munt/...) - without
                  this the order would keep the field default (0), which
                  is not a valid regime (see Luna.BusinessLogic.btw-regime
                  lookup table) and would leave the VAT handling/GL account
                  for the purchase order undetermined.
    Syntax      : Called from Luna.Web.LakproductieHandler (POST
                  /web/lakproduktie/bestelling)
    Description : Owns all DB access for this feature - no direct DB
                  access is allowed from the WebHandler layer.
                  EXCLUSIVE-LOCK within a single transaction for the
                  header, every line, and every bonlijn/bonlijn_productie
                  counter bump - either the whole bestelling is created, or
                  none of it is.
    Author(s)   : Devin
    Created     : 2026-08-18
    Updated     : 2026-08-19 - copy lever.btw-reg (BTW-regime) onto the new
                  order header, it was previously left at the field
                  default (0) instead of the supplier's regime.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LakproductieBestellingBE:

    /* Explicit buffer alias for the `order` table - never reference a bare
       `order` buffer in this class, ORDER is an ABL/SQL-reserved word. */
    DEFINE BUFFER bBestelling FOR order.

    /* Header result - single row, SERIALIZE-NAME controls the JSON array
       key so the response reads as {"items": [...]}, same convention as
       Luna.BusinessLogic.BestelorderBE. */
    DEFINE TEMP-TABLE ttBestelling NO-UNDO SERIALIZE-NAME "items":u
        FIELD ordnr    AS INTEGER   SERIALIZE-NAME "ordnr":u
        FIELD levnr    AS INTEGER   SERIALIZE-NAME "levnr":u
        FIELD naam     AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD datum    AS DATE      SERIALIZE-NAME "datum":u
        FIELD munt     AS CHARACTER SERIALIZE-NAME "munt":u
        INDEX idx-ordnr IS PRIMARY ordnr.

    /* Line result - SERIALIZE-NAME controls the JSON array key so the
       response reads as {"lines": [...]}. */
    DEFINE TEMP-TABLE ttBestellingLijn NO-UNDO SERIALIZE-NAME "lines":u
        FIELD ordnr        AS INTEGER   SERIALIZE-NAME "ordnr":u
        FIELD lijnnr       AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD aantal       AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD bonnr        AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD blijnnr      AS INTEGER   SERIALIZE-NAME "blijnnr":u
        FIELD volgnr       AS INTEGER   SERIALIZE-NAME "volgnr":u
        INDEX idx-lijnnr IS PRIMARY ordnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Validates the top-level request body shape and the
                 `levnr` (must exist in `lever`).
        Errors : AppError 400 - missing/invalid `levnr` or `lines`.
                 AppError 404 - `levnr` doesn't exist in `lever`.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateRequest( INPUT poBody AS JsonObject, OUTPUT poLines AS JsonArray ):

        IF NOT poBody:Has("levnr":u) THEN
            UNDO, THROW NEW Progress.Lang.AppError("levnr is required":u, 400).

        IF NOT poBody:Has("lines":u) OR poBody:GetJsonArray("lines":u):Length EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError("At least one line is required":u, 400).

        FIND FIRST lever NO-LOCK WHERE lever.levnr EQ poBody:GetInteger("levnr":u) NO-ERROR.
        IF NOT AVAILABLE lever THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Leverancier &1 not found":u, poBody:GetInteger("levnr":u)), 404).

        poLines = poBody:GetJsonArray("lines":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates a single line entry: `artnr` (required, must
                 exist in `artikel`) and `aantal` (required, > 0).
        Errors : AppError 400 - missing/invalid `artnr` or `aantal`.
                 AppError 404 - `artnr` doesn't exist in `artikel`.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateLine( INPUT piIndex AS INTEGER, INPUT poLine AS JsonObject ):

        IF NOT poLine:Has("artnr":u) OR poLine:GetCharacter("artnr":u) EQ "":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Line &1: artnr is required":u, piIndex), 400).

        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ poLine:GetCharacter("artnr":u) NO-ERROR.
        IF NOT AVAILABLE artikel THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Line &1: artikel &2 not found":u, piIndex, poLine:GetCharacter("artnr":u)), 404).

        IF NOT poLine:Has("aantal":u) OR poLine:GetDecimal("aantal":u) LE 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Line &1: aantal must be greater than 0":u, piIndex), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Bumps the `besteld` counter on the customer order line
                 (bonlijn or bonlijn_productie) that a purchase-order line
                 is linked to, so the Lakproduktie overview picks up the
                 new status - mirrors the fields ResolveOrderInfo() (in
                 Luna.BusinessLogic.LakproductieBE) reads back later.
                 No-op if the line has no bonnr (min-max-voorraad lines).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID BumpBonlijnBesteld(
        INPUT piBonnr   AS INTEGER,
        INPUT piBlijnnr AS INTEGER,
        INPUT piVolgnr  AS INTEGER,
        INPUT pdAantal  AS DECIMAL ):

        IF piBonnr EQ ? OR piBonnr EQ 0 THEN
            RETURN.

        IF piVolgnr NE ? AND piVolgnr NE 0 THEN
        DO:
            FIND FIRST bonlijn_productie EXCLUSIVE-LOCK
                WHERE bonlijn_productie.bonnr   EQ piBonnr
                  AND bonlijn_productie.blijnnr EQ piBlijnnr
                  AND bonlijn_productie.lijnnr  EQ piVolgnr NO-ERROR.
            IF AVAILABLE bonlijn_productie THEN
                bonlijn_productie.besteld = bonlijn_productie.besteld + pdAantal.
            RETURN.
        END.

        FIND FIRST bonlijn EXCLUSIVE-LOCK
            WHERE bonlijn.bonnr  EQ piBonnr
              AND bonlijn.lijnnr EQ piBlijnnr NO-ERROR.
        IF AVAILABLE bonlijn THEN
            bonlijn.besteld = bonlijn.besteld + pdAantal.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new purchase order ("order") and its lines
                 ("ordlijn") from a Lakproduktie bestelling-preview.
                 `ordnr` is computed server-side (last ordnr, via the
                 order-x1 index, + 1) and `lijnnr` per line is a simple
                 10/20/30/... sequence, both inside the same transaction as
                 every CREATE/UPDATE below - either the whole bestelling is
                 created (including every bonlijn/bonlijn_productie
                 `besteld` bump), or none of it is.
        Request : { "levnr": <int>, "lines": [ { "artnr", "omschrijving",
                 "aantal", "bonnr"?, "blijnnr"?, "volgnr"? }, ... ] }.
                 `bonnr`/`blijnnr` link a line back to a customer order
                 line (bonlijn); adding `volgnr` on top of that links it to
                 a production line (bonlijn_productie) instead. Omit all
                 three for a pure stock-replenishment line
                 (min-max-voorraad, no customer link).
        Output  : Returns the ttBestelling handle (header, single row);
                 `phLines` is set to the ttBestellingLijn handle (one row
                 per created ordlijn).
        Errors  : AppError 400 - invalid/missing levnr, lines, artnr or
                 aantal. AppError 404 - levnr or a line's artnr doesn't
                 exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBestelling( INPUT poBody AS JsonObject, OUTPUT phLines AS HANDLE ):

        DEFINE VARIABLE oLines     AS JsonArray  NO-UNDO.
        DEFINE VARIABLE oLine      AS JsonObject NO-UNDO.
        DEFINE VARIABLE iNewOrdnr  AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLevnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iLijnnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iIdx       AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBonnr     AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iBlijnnr   AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iVolgnr    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE dAantal    AS DECIMAL    NO-UNDO.

        ValidateRequest( INPUT poBody, OUTPUT oLines ).

        /* Validate every line up front (before creating anything) so a
           bad line further down the array never leaves a partially
           created order behind. */
        DO iIdx = 1 TO oLines:Length:
            ValidateLine( iIdx, oLines:GetJsonObject(iIdx) ).
        END.

        iLevnr = poBody:GetInteger("levnr":u).

        EMPTY TEMP-TABLE ttBestelling.
        EMPTY TEMP-TABLE ttBestellingLijn.

        DO TRANSACTION:
            FIND FIRST lever NO-LOCK WHERE lever.levnr EQ iLevnr NO-ERROR.

            FIND LAST bBestelling USE-INDEX order-x1 EXCLUSIVE-LOCK NO-ERROR.
            iNewOrdnr = (IF AVAILABLE bBestelling THEN bBestelling.ordnr ELSE 0) + 1.

            CREATE bBestelling.
            ASSIGN
                bBestelling.ordnr   = iNewOrdnr
                bBestelling.levnr   = iLevnr
                bBestelling.naam    = lever.naam
                bBestelling.naam1   = lever.naam1
                bBestelling.adres   = lever.adres
                bBestelling.postnr  = lever.postnr
                bBestelling.stad    = lever.stad
                bBestelling.taal    = lever.taal
                bBestelling.land    = lever.land
                bBestelling.munt    = lever.munt
                bBestelling.btw-reg = lever.btw-reg
                bBestelling.datum   = TODAY
                .

            iLijnnr = 0.
            DO iIdx = 1 TO oLines:Length:
                oLine   = oLines:GetJsonObject(iIdx).
                iLijnnr = iLijnnr + 10.
                dAantal = oLine:GetDecimal("aantal":u).

                iBonnr   = (IF oLine:Has("bonnr":u)   THEN oLine:GetInteger("bonnr":u)   ELSE ?).
                iBlijnnr = (IF oLine:Has("blijnnr":u) THEN oLine:GetInteger("blijnnr":u) ELSE ?).
                iVolgnr  = (IF oLine:Has("volgnr":u)  THEN oLine:GetInteger("volgnr":u)  ELSE ?).

                CREATE ordlijn.
                ASSIGN
                    ordlijn.ordnr      = iNewOrdnr
                    ordlijn.lijnnr     = iLijnnr
                    ordlijn.artnr      = oLine:GetCharacter("artnr":u)
                    ordlijn.omschr     = (IF oLine:Has("omschrijving":u) THEN oLine:GetCharacter("omschrijving":u) ELSE "":u)
                    ordlijn.aantal     = dAantal
                    ordlijn.te-leveren = dAantal
                    ordlijn.levnr      = iLevnr
                    .
                IF iBonnr NE ? THEN ordlijn.bonnr = iBonnr.
                IF iBlijnnr NE ? THEN ordlijn.blijnnr = iBlijnnr.
                IF iVolgnr NE ? THEN ordlijn.volgnr = iVolgnr.

                BumpBonlijnBesteld( iBonnr, iBlijnnr, iVolgnr, dAantal ).

                CREATE ttBestellingLijn.
                ASSIGN
                    ttBestellingLijn.ordnr        = iNewOrdnr
                    ttBestellingLijn.lijnnr       = iLijnnr
                    ttBestellingLijn.artnr        = ordlijn.artnr
                    ttBestellingLijn.omschrijving = ordlijn.omschr
                    ttBestellingLijn.aantal       = dAantal
                    ttBestellingLijn.bonnr        = iBonnr
                    ttBestellingLijn.blijnnr      = iBlijnnr
                    ttBestellingLijn.volgnr       = iVolgnr
                    .
            END.

            CREATE ttBestelling.
            ASSIGN
                ttBestelling.ordnr = iNewOrdnr
                ttBestelling.levnr = iLevnr
                ttBestelling.naam  = bBestelling.naam
                ttBestelling.datum = bBestelling.datum
                ttBestelling.munt  = bBestelling.munt
                .
        END.

        phLines = TEMP-TABLE ttBestellingLijn:HANDLE.
        RETURN TEMP-TABLE ttBestelling:HANDLE.

    END METHOD.

END CLASS.
