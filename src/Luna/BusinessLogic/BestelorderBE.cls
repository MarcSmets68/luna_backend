/*------------------------------------------------------------------------ 
    File        : BestelorderBE.cls 
    Purpose     : Business Entity for the "order" table (purchase orders
                  to suppliers/leveranciers) - read-only access to a
                  curated core subset of fields (identification, supplier,
                  amount, delivery, status). The order table has ~35
                  fields in total; only the subset below is exposed via
                  the API for now.
    Field map (JSON key -> order column): 
                  ordnr      -> ordnr 
                  stempel    -> stempel    (raw code, no label mapping) 
                  datum      -> datum 
                  levnr      -> levnr 
                  naam       -> naam 
                  stad       -> stad 
                  munt       -> munt 
                  bedrag     -> b-bedrag   (bruto/gross total) 
                  levDatum   -> lev-dat 
                  geparkeerd -> geparkeerd 
                  uRef       -> u-ref 
                  opm        -> opm 
    Notes       : Named "Bestelorder" rather than "Order" throughout this
                  feature (class name, buffer alias, endpoint path) to
                  avoid the ABL/SQL-reserved word `ORDER` and to avoid
                  confusion with the existing `bon`-based "Orders &
                  Productie" feature (Luna.BusinessLogic.BonBE) which is a
                  different table (customer sales orders, not purchase
                  orders to suppliers). All DB access below goes through
                  an explicit buffer alias (bBestelorder) rather than a
                  bare `order` buffer.
                  Same pagination approach as Luna.BusinessLogic.BonBE:
                  GetBonnen() - this deliberately does NOT compute an
                  exact total count, instead it stops scanning as soon as
                  it has one extra row beyond the requested page and
                  reports that via plHasMore. levnr uses the existing
                  order-x3 index.
                  GetBestelorders() additionally supports filtering by
                  ordnr (prefix match on the string form, so partial
                  numbers typed by the user still match) and naam/
                  leverancier (substring match, same convention as
                  Luna.BusinessLogic.FactuurBE:GetFacturen()), plus
                  sorting on ordnr/datum/naam/stempel in either direction.
                  Sorting on a non-ordnr field (or filtering at all) means
                  the ordnr-descending index can no longer be used to
                  short-circuit the scan, so matching rows are staged in
                  ttBestelorderAll first and only then sorted/paged into
                  ttBestelorder - see EmitRow(). This keeps every FOR EACH
                  below static (no dynamic queries), consistent with the
                  rest of this codebase.
    Syntax      : Called from Luna.Web.BestelorderHandler (GET
                  /web/bestelorder and /web/bestelorder/{ordnr}) 
    Description : Owns all DB access for this feature - no direct DB access 
                  is allowed from the WebHandler layer. NO-LOCK for reads.
                  Read-only: no Create/Update/Delete methods exist on this
                  class - that is intentional, not an oversight.
    Author(s)   : Devin 
    Created     : 2026-08-12 
    Updated     : 2026-08-18 - added ordnr/naam filtering and
                  ordnr/datum/naam/stempel sorting to GetBestelorders(),
                  for the "filters en sortering voor bestellingen" feature.
  ----------------------------------------------------------------------*/ 

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW. 

CLASS Luna.BusinessLogic.BestelorderBE: 

    /* Explicit buffer alias for the `order` table - never reference a
       bare `order` buffer in this class, ORDER is an ABL/SQL-reserved
       word. */
    DEFINE BUFFER bBestelorder FOR order.

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the 
       JSON array key so list responses read as {"items": [...]}. */ 
    DEFINE TEMP-TABLE ttBestelorder NO-UNDO SERIALIZE-NAME "items":u 
        FIELD ordnr      AS INTEGER   SERIALIZE-NAME "ordnr":u 
        FIELD stempel    AS CHARACTER SERIALIZE-NAME "stempel":u 
        FIELD datum      AS DATE      SERIALIZE-NAME "datum":u 
        FIELD levnr      AS INTEGER   SERIALIZE-NAME "levnr":u 
        FIELD naam       AS CHARACTER SERIALIZE-NAME "naam":u 
        FIELD stad       AS CHARACTER SERIALIZE-NAME "stad":u 
        FIELD munt       AS CHARACTER SERIALIZE-NAME "munt":u 
        FIELD bedrag     AS DECIMAL   SERIALIZE-NAME "bedrag":u 
        FIELD levDatum   AS DATE      SERIALIZE-NAME "levDatum":u 
        FIELD geparkeerd AS LOGICAL   SERIALIZE-NAME "geparkeerd":u 
        FIELD uRef       AS CHARACTER SERIALIZE-NAME "uRef":u 
        FIELD opm        AS CHARACTER SERIALIZE-NAME "opm":u 
        INDEX idx-ordnr IS PRIMARY ordnr DESCENDING. 

    /* Unsorted staging area for GetBestelorders(): every row matching the
       filters, gathered in a single pass, before EmitRow() sorts/pages
       them into ttBestelorder. Same field layout as ttBestelorder but no
       SERIALIZE-NAME/index - this temp-table is never returned to the
       caller. */
    DEFINE TEMP-TABLE ttBestelorderAll NO-UNDO
        FIELD ordnr      AS INTEGER
        FIELD stempel    AS CHARACTER
        FIELD datum      AS DATE
        FIELD levnr      AS INTEGER
        FIELD naam       AS CHARACTER
        FIELD stad       AS CHARACTER
        FIELD munt       AS CHARACTER
        FIELD bedrag     AS DECIMAL
        FIELD levDatum   AS DATE
        FIELD geparkeerd AS LOGICAL
        FIELD uRef       AS CHARACTER
        FIELD opm        AS CHARACTER.

    /*------------------------------------------------------------------------------ 
        Purpose: Copies the core subset of fields from a bBestelorder
                 buffer into a ttBestelorder row, for use by every read
                 method below. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE VOID CopyToTt( BUFFER pbBestelorder FOR order, BUFFER pbTt FOR ttBestelorder ): 

        ASSIGN 
            pbTt.ordnr      = pbBestelorder.ordnr 
            pbTt.stempel    = pbBestelorder.stempel 
            pbTt.datum      = pbBestelorder.datum 
            pbTt.levnr      = pbBestelorder.levnr 
            pbTt.naam       = pbBestelorder.naam 
            pbTt.stad       = pbBestelorder.stad 
            pbTt.munt       = pbBestelorder.munt 
            pbTt.bedrag     = pbBestelorder.b-bedrag 
            pbTt.levDatum   = pbBestelorder.lev-dat 
            pbTt.geparkeerd = pbBestelorder.geparkeerd 
            pbTt.uRef       = pbBestelorder.u-ref 
            pbTt.opm        = pbBestelorder.opm 
            . 

    END METHOD. 

    /*------------------------------------------------------------------------------
        Purpose: Copies a ttBestelorderAll row into ttBestelorder. Both
                 temp-tables have identical field names, so BUFFER-COPY
                 (name-based) is used rather than a field-by-field ASSIGN.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyAllToTt( BUFFER pbAll FOR ttBestelorderAll, BUFFER pbTt FOR ttBestelorder ):

        BUFFER-COPY pbAll TO pbTt.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Applies skip/take pagination to a single already-sorted
                 ttBestelorderAll row: increments piSeen, and either skips
                 the row (still before the requested page), copies it into
                 ttBestelorder (within the requested page), or marks
                 plHasMore and requests the caller LEAVE its FOR EACH
                 (page already full, one extra row seen) via plStop.
                 Factored out so every sort-order branch in
                 GetBestelorders() can share the same pagination logic
                 instead of repeating it eight times.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID EmitRow(
        BUFFER pbAll FOR ttBestelorderAll,
        INPUT  piSkip     AS INTEGER,
        INPUT  piPageSize AS INTEGER,
        INPUT-OUTPUT piSeen AS INTEGER,
        INPUT-OUTPUT piTaken AS INTEGER,
        OUTPUT plStop     AS LOGICAL,
        INPUT-OUTPUT plHasMore AS LOGICAL ):

        DEFINE BUFFER bOut FOR ttBestelorder.

        plStop = FALSE.
        piSeen = piSeen + 1.

        IF piSeen LE piSkip THEN RETURN.

        IF piTaken GE piPageSize THEN
        DO:
            plHasMore = TRUE.
            plStop    = TRUE.
            RETURN.
        END.

        CREATE bOut.
        CopyAllToTt( BUFFER pbAll, BUFFER bOut ).
        piTaken = piTaken + 1.

    END METHOD.

    /*------------------------------------------------------------------------------ 
        Purpose: Returns a page of order rows, optionally filtered by
                 levnr (exact), ordnr (prefix match on the string form)
                 and naam/leverancier (substring match), sorted by
                 pcSortField ("ordnr", "datum", "naam" or "stempel";
                 anything else falls back to "ordnr") in pcSortDir
                 ("asc" or "desc"; anything else falls back to "desc"). 
        Notes  : NO-LOCK read-only. piPage/piPageSize/pcSortField/pcSortDir
                 are expected to already be validated/clamped by the
                 caller. Same overall approach as
                 Luna.BusinessLogic.BonBE:GetBonnen() - this deliberately
                 does NOT compute an exact total count, instead it stops
                 scanning as soon as it has one extra row beyond the
                 requested page and reports that via plHasMore. Filtering
                 (levnr uses the existing order-x3 index; ordnr/naam do
                 not) happens in a first pass into ttBestelorderAll, then
                 EmitRow() sorts/pages that staged set into ttBestelorder -
                 see the class header for why.
    ------------------------------------------------------------------------------*/ 
    METHOD PUBLIC HANDLE GetBestelorders( 
        INPUT  piLevnr     AS INTEGER, 
        INPUT  pcOrdnr     AS CHARACTER,
        INPUT  pcNaam      AS CHARACTER,
        INPUT  pcSortField AS CHARACTER,
        INPUT  pcSortDir   AS CHARACTER,
        INPUT  piPage      AS INTEGER, 
        INPUT  piPageSize  AS INTEGER, 
        OUTPUT plHasMore   AS LOGICAL ): 

        DEFINE VARIABLE iSkip   AS INTEGER NO-UNDO. 
        DEFINE VARIABLE iSeen   AS INTEGER NO-UNDO. 
        DEFINE VARIABLE iTaken  AS INTEGER NO-UNDO. 
        DEFINE VARIABLE lDesc   AS LOGICAL NO-UNDO.
        DEFINE VARIABLE lStop   AS LOGICAL NO-UNDO.

        DEFINE BUFFER bAll FOR ttBestelorderAll.

        EMPTY TEMP-TABLE ttBestelorder. 
        EMPTY TEMP-TABLE ttBestelorderAll.

        ASSIGN 
            pcOrdnr   = TRIM(pcOrdnr)
            pcNaam    = UPPER(TRIM(pcNaam))
            lDesc     = pcSortDir NE "asc":u
            iSkip     = (piPage - 1) * piPageSize 
            iSeen     = 0 
            iTaken    = 0 
            plHasMore = FALSE 
            . 

        /* Stage 1: gather every matching row - unsorted, no early stop,
           since sorting on anything but ordnr needs the full match set
           before pagination can be applied. */
        FOR EACH bBestelorder NO-LOCK 
            WHERE (piLevnr LE 0 OR bBestelorder.levnr EQ piLevnr) 
              AND (pcOrdnr EQ "":u OR STRING(bBestelorder.ordnr) BEGINS pcOrdnr)
              AND (pcNaam  EQ "":u OR INDEX(UPPER(bBestelorder.naam), pcNaam) GT 0):

            CREATE bAll.
            ASSIGN
                bAll.ordnr      = bBestelorder.ordnr
                bAll.stempel    = bBestelorder.stempel
                bAll.datum      = bBestelorder.datum
                bAll.levnr      = bBestelorder.levnr
                bAll.naam       = bBestelorder.naam
                bAll.stad       = bBestelorder.stad
                bAll.munt       = bBestelorder.munt
                bAll.bedrag     = bBestelorder.b-bedrag
                bAll.levDatum   = bBestelorder.lev-dat
                bAll.geparkeerd = bBestelorder.geparkeerd
                bAll.uRef       = bBestelorder.u-ref
                bAll.opm        = bBestelorder.opm
                .
        END. 

        /* Stage 2: sorted/paged pass into ttBestelorder. Each branch is a
           plain static FOR EACH (no dynamic queries, consistent with the
           rest of this codebase) - EmitRow() carries the shared
           skip/take/plHasMore logic so the branches themselves stay a
           single line each. */
        CASE pcSortField:
            WHEN "datum":u THEN
            DO:
                IF lDesc THEN
                    FOR EACH bAll NO-LOCK BY bAll.datum DESCENDING BY bAll.ordnr DESCENDING:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
                ELSE
                    FOR EACH bAll NO-LOCK BY bAll.datum BY bAll.ordnr:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
            END.
            WHEN "naam":u THEN
            DO:
                IF lDesc THEN
                    FOR EACH bAll NO-LOCK BY bAll.naam DESCENDING BY bAll.ordnr DESCENDING:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
                ELSE
                    FOR EACH bAll NO-LOCK BY bAll.naam BY bAll.ordnr:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
            END.
            WHEN "stempel":u THEN
            DO:
                IF lDesc THEN
                    FOR EACH bAll NO-LOCK BY bAll.stempel DESCENDING BY bAll.ordnr DESCENDING:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
                ELSE
                    FOR EACH bAll NO-LOCK BY bAll.stempel BY bAll.ordnr:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
            END.
            OTHERWISE
            DO:
                /* "ordnr" (and any unrecognized pcSortField). */
                IF lDesc THEN
                    FOR EACH bAll NO-LOCK BY bAll.ordnr DESCENDING:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
                ELSE
                    FOR EACH bAll NO-LOCK BY bAll.ordnr:
                        EmitRow( BUFFER bAll, iSkip, piPageSize, INPUT-OUTPUT iSeen, INPUT-OUTPUT iTaken, OUTPUT lStop, INPUT-OUTPUT plHasMore ).
                        IF lStop THEN LEAVE.
                    END.
            END.
        END CASE.

        RETURN TEMP-TABLE ttBestelorder:HANDLE. 

    END METHOD. 

    /*------------------------------------------------------------------------------
        Purpose: Returns a single order by ordnr, or an empty
                 ttBestelorder if it doesn't exist (the WebHandler turns
                 that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetBestelorder( INPUT piOrdnr AS INTEGER ):

        EMPTY TEMP-TABLE ttBestelorder.

        FIND FIRST bBestelorder NO-LOCK WHERE bBestelorder.ordnr EQ piOrdnr NO-ERROR.

        IF AVAILABLE bBestelorder THEN
        DO:
            CREATE ttBestelorder.
            CopyToTt( BUFFER bBestelorder, BUFFER ttBestelorder ).
        END.

        RETURN TEMP-TABLE ttBestelorder:HANDLE.

    END METHOD.

END CLASS. 
