/*------------------------------------------------------------------------
    File        : LakproductieVerkoopService.cls
    Purpose     : Computes rolling ordered-quantity ("verkoop") totals per
                  artnr, trailing 1/3/6/9/12 months from TODAY, used by
                  Luna.BusinessLogic.LakproductieBE to enrich every row of
                  the "Lakproduktie" overview (GET /lakproduktie) regardless
                  of which of the 3 sources (lopende orders / lopende
                  productielijnen / min-max voorraad) that row came from.
    Business rule (confirmed with Marc, 2026-08-17):
                  - 1:1 port of legacy ExportLakProductie.w's
                    maak-lijst-verkoop / bereken-verkoop procedures
                    (N:\LunaV12\ExportLakProductie.w), computed once up
                    front and shared across all 3 sources built by
                    LakproductieBE, instead of the legacy tool's approach
                    of an intermediate tblVerkoop temp-table populated by a
                    dedicated pass right before export.
                  - Base pass: every bonlijn row from the last 365 days
                    (bon-datum >= TODAY - 365, excluding kolomtitel/
                    infolijn/subtotaal rows and rows with no artnr) credits
                    its own artnr's buckets - v12 always, v9/v6/v3/v1 only
                    when bon-datum also falls within that narrower window
                    (TODAY-274/182/91/30 respectively).
                  - Brut-artikel chain: when that bonlijn's artikel has a
                    filled-in led-alu, legacy walks the led-alu chain (via
                    GetTree.p) to find the "brut" (raw/unfinished) base
                    article and credits it with the same quantity/date. Bug
                    fix vs legacy, explicitly signed off by Marc on
                    2026-08-17: in ExportLakProductie.w this walk's loop
                    (`DO WHILE pcNextArtnr <> ""`) only ever exits when
                    GetTree.p returns "" (the chain is broken / artikel not
                    found) - GetTree.p never returns "" for an artikel whose
                    OWN led-alu is empty in a way that lets the loop capture
                    it, so the `IF pcNextArtnr <> ""` guard immediately
                    after the loop can never be true - the legacy
                    brut-artikel credit is dead code and never actually
                    fires in production. This port fixes that:
                    ResolveBrutArtnr() below walks the same chain but stops
                    and returns the resolved base artnr as soon as it finds
                    an artikel whose OWN led-alu is empty (the real
                    terminus), so the credit fires as originally intended.
                    Also hardened with a cycle guard (max 20 hops / revisit
                    detection) that legacy did not have.
                  - Composite article ("samengesteld artikel", artikel.soort
                    = TRUE) decomposition: ported as-is - this part was
                    already live/correct in legacy. Every artlijn component
                    of such an artikel is credited with
                    bonlijn.aantal * artlijn.aantal, and if that component
                    itself has a led-alu, its own brut-artikel chain is
                    also credited with the same multiplied quantity (this
                    inner walk uses the same bug-fixed ResolveBrutArtnr()
                    logic - legacy's inner walk has the identical dead-code
                    bug, fixed here for the same reason).
    Syntax      : Called from Luna.BusinessLogic.LakproductieBE.
                  GetOpenLakproductieItems() as the very first step - every
                  source-builder method then looks up its own artnr in the
                  returned ttVerkoop temp-table (0 when not found).
    Description : Read-only - NO-LOCK throughout, no writes.
    Author(s)   : Devin
    Created     : 2026-08-17
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.LakproductieVerkoopService:

    /* Not serialized directly - LakproductieBE consumes this via a dynamic
       buffer (CREATE BUFFER ... FOR TABLE) rather than a static reference,
       since it lives in a different class. */
    DEFINE TEMP-TABLE ttVerkoop NO-UNDO
        FIELD artnr AS CHARACTER
        FIELD v1    AS DECIMAL
        FIELD v3    AS DECIMAL
        FIELD v6    AS DECIMAL
        FIELD v9    AS DECIMAL
        FIELD v12   AS DECIMAL
        INDEX idx-artnr IS UNIQUE artnr.

    /* Cycle guard for ResolveBrutArtnr() - bounds the led-alu chain walk to
       at most this many hops. */
    DEFINE PRIVATE VARIABLE iMaxChainHops AS INTEGER NO-UNDO INITIAL 20.

    /*------------------------------------------------------------------------------
        Purpose: Builds the rolling 1/3/6/9/12-month ordered-quantity totals per
                 artnr described in the class header above.
        Notes  : NO-LOCK reads only.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE BerekenVerkoopCijfers():

        DEFINE VARIABLE cResolved AS CHARACTER NO-UNDO.

        DEFINE BUFFER bfArtikel FOR artikel.

        EMPTY TEMP-TABLE ttVerkoop.

        FOR EACH bonlijn NO-LOCK USE-INDEX bonlijn-x17
            WHERE bonlijn.bon-datum GE TODAY - 365
              AND bonlijn.kolomtitel EQ FALSE
              AND bonlijn.infolijn   EQ FALSE
              AND bonlijn.subtotaal  EQ FALSE
              AND bonlijn.artnr      NE "":u:

            CreditVerkoop(bonlijn.artnr, bonlijn.aantal, bonlijn.bon-datum).

            FIND FIRST artikel NO-LOCK WHERE artikel.artnr = bonlijn.artnr NO-ERROR.

            /* --- Brut-artikel chain (bug-fixed vs legacy, see class header) --- */
            IF AVAILABLE artikel AND artikel.led-alu NE "":u THEN DO:
                ResolveBrutArtnr(artikel.led-alu, OUTPUT cResolved).
                IF cResolved NE "":u THEN
                    CreditVerkoop(cResolved, bonlijn.aantal, bonlijn.bon-datum).
            END.

            /* --- Composite article decomposition (ported as-is) --- */
            IF AVAILABLE artikel AND artikel.soort THEN DO:
                FOR EACH artlijn NO-LOCK WHERE artlijn.artnr = bonlijn.artnr:

                    CreditVerkoop(
                        artlijn.l-artnr,
                        bonlijn.aantal * artlijn.aantal,
                        bonlijn.bon-datum).

                    FIND FIRST bfArtikel NO-LOCK WHERE bfArtikel.artnr = artlijn.l-artnr NO-ERROR.
                    IF AVAILABLE bfArtikel AND bfArtikel.led-alu NE "":u THEN DO:
                        ResolveBrutArtnr(bfArtikel.led-alu, OUTPUT cResolved).
                        IF cResolved NE "":u THEN
                            CreditVerkoop(
                                cResolved,
                                bonlijn.aantal * artlijn.aantal,
                                bonlijn.bon-datum).
                    END.
                END.
            END.
        END.

        RETURN TEMP-TABLE ttVerkoop:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Credits pdAantal to pcArtnr's rolling buckets, creating the
                 ttVerkoop row on first use. Mirrors legacy bereken-verkoop's
                 exact date cutoffs (TODAY-30/91/182/274/365).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CreditVerkoop(
        INPUT pcArtnr  AS CHARACTER,
        INPUT pdAantal AS DECIMAL,
        INPUT pdDatum  AS DATE ):

        FIND FIRST ttVerkoop WHERE ttVerkoop.artnr = pcArtnr NO-ERROR.
        IF NOT AVAILABLE ttVerkoop THEN DO:
            CREATE ttVerkoop.
            ttVerkoop.artnr = pcArtnr.
        END.

        ttVerkoop.v12 = ttVerkoop.v12 + pdAantal.

        IF pdDatum GE TODAY - 274 THEN
            ttVerkoop.v9 = ttVerkoop.v9 + pdAantal.

        IF pdDatum GE TODAY - 182 THEN
            ttVerkoop.v6 = ttVerkoop.v6 + pdAantal.

        IF pdDatum GE TODAY - 91 THEN
            ttVerkoop.v3 = ttVerkoop.v3 + pdAantal.

        IF pdDatum GE TODAY - 30 THEN
            ttVerkoop.v1 = ttVerkoop.v1 + pdAantal.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Walks the led-alu chain starting at pcStartLedAlu (the caller
                 already passes the first hop, e.g. artikel.led-alu - not the
                 owning artikel's own artnr) to find the "brut" (raw/
                 unfinished) base article: the first artikel in the chain whose
                 OWN led-alu is empty. Returns "" (unresolved) when the chain
                 is broken (an artnr in the chain doesn't exist as an artikel),
                 when it doesn't terminate within iMaxChainHops hops, or when it
                 revisits an artnr already seen in this walk (cycle guard) -
                 never throws.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ResolveBrutArtnr(
        INPUT  pcStartLedAlu   AS CHARACTER,
        OUTPUT pcResolvedArtnr AS CHARACTER ):

        DEFINE VARIABLE cCurrent AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cVisited AS CHARACTER NO-UNDO INITIAL "":u.
        DEFINE VARIABLE iHops    AS INTEGER   NO-UNDO INITIAL 0.

        DEFINE BUFFER bfChain FOR artikel.

        pcResolvedArtnr = "":u.
        cCurrent = pcStartLedAlu.

        DO WHILE iHops LT iMaxChainHops:

            IF LOOKUP(cCurrent, cVisited, "|":u) GT 0 THEN
                RETURN. /* cycle guard tripped */

            cVisited = cVisited + (IF cVisited EQ "":u THEN "":u ELSE "|":u) + cCurrent.
            iHops = iHops + 1.

            FIND FIRST bfChain NO-LOCK WHERE bfChain.artnr = cCurrent NO-ERROR.
            IF NOT AVAILABLE bfChain THEN
                RETURN. /* chain broken - artnr not found */

            IF bfChain.led-alu EQ "":u THEN DO:
                pcResolvedArtnr = bfChain.artnr.
                RETURN.
            END.

            cCurrent = bfChain.led-alu.
        END.

        /* iMaxChainHops exceeded without terminating - leave unresolved. */

    END METHOD.

END CLASS.
