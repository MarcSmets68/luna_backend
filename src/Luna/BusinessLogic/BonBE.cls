/*------------------------------------------------------------------------ 
    File        : BonBE.cls 
    Purpose     : Business Entity for the "bon" (customer order) table - 
                  full CRUD access for a curated core subset of fields 
                  (identification, customer, amounts, status). The bon 
                  table has ~70 fields in total; only the subset below is 
                  exposed via the API for now. 
    Field map (JSON key -> bon column): 
                  bonnr        -> bonnr        (PK, server-generated, not writable via API) 
                  type         -> type 
                  stempel      -> stempel      (raw code, no label mapping) 
                  datum        -> datum 
                  klnr         -> klnr 
                  naam         -> naam 
                  adres        -> adres 
                  postnr       -> postnr 
                  stad         -> stad 
                  munt         -> munt 
                  bedrag       -> b-bedrag     (bruto/gross total, not writable via API) 
                  btw          -> tot-btw      (not writable via API) 
                  uRef         -> u-ref 
                  besteldatum  -> bestel-datum 
                  levDatum     -> lev-dat 
                  geparkeerd   -> geparkeerd 
                  verzonden    -> verzonden 
                  opm          -> opm 
                  recupelBedrag -> recupel-bedrag (regular read/write field, like uRef/opm -
                                 not a computed total; distinct from bedrag/btw which stay
                                 read-only)
                  aBedrag      -> a-bedrag     (regular read/write field, same rationale)
                  klnr2        -> klnr2        (multi-klant, no validation against klant table)
                  klnr3        -> klnr3        (multi-klant, no validation against klant table)
                  lnaam        -> lnaam        (afleveradres)
                  lnaam1       -> lnaam1       (afleveradres)
                  ladres       -> ladres       (afleveradres)
                  lpostnr      -> lpostnr      (afleveradres)
                  lstad        -> lstad        (afleveradres)
    Notes       : Same pagination approach as Luna.BusinessLogic.OfferteBE: 
                  GetOffertes() / Luna.BusinessLogic.KlantBE:GetKlanten() - 
                  this deliberately does NOT compute an exact total count, 
                  instead it stops scanning as soon as it has one extra row 
                  beyond the requested page and reports that via 
                  plHasMore. klnr uses the existing bon-x3 index; a 
                  type-only filter (without klnr) scans every row in the 
                  table and should be combined with klnr where possible. 
                  `bonnr` is assigned server-side (last bonnr + 1, via the
                  bon-x1 index) inside the same transaction as the CREATE
                  to avoid a race between the FIND LAST and the CREATE.
                  `bonnr`, `bedrag` (b-bedrag) and `btw` (tot-btw) are never
                  read from the request body on create/update - bedrag/btw
                  are computed totals owned by the order-lines feature, not
                  settable directly via this API.
    Syntax      : Called from Luna.Web.BonHandler (GET/POST/PUT/DELETE
                  /web/bon and /web/bon/{bonnr}) 
    Description : Owns all DB access for this feature - no direct DB access 
                  is allowed from the WebHandler layer. NO-LOCK for reads,
                  EXCLUSIVE-LOCK within a transaction for writes. 
    Author(s)   : Devin 
    Created     : 2026-08-11 
  ----------------------------------------------------------------------*/ 
 
USING Progress.Lang.*.
USING Progress.Json.ObjectModel.JsonObject. 
 
BLOCK-LEVEL ON ERROR UNDO, THROW. 
 
CLASS Luna.BusinessLogic.BonBE: 
 
    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the 
       JSON array key so list responses read as {"items": [...]}. */ 
    DEFINE TEMP-TABLE ttBon NO-UNDO SERIALIZE-NAME "items":u 
        FIELD bonnr       AS INTEGER   SERIALIZE-NAME "bonnr":u 
        FIELD type        AS CHARACTER SERIALIZE-NAME "type":u 
        FIELD stempel     AS CHARACTER SERIALIZE-NAME "stempel":u 
        FIELD datum       AS DATE      SERIALIZE-NAME "datum":u 
        FIELD klnr        AS INTEGER   SERIALIZE-NAME "klnr":u 
        FIELD naam        AS CHARACTER SERIALIZE-NAME "naam":u 
        FIELD adres       AS CHARACTER SERIALIZE-NAME "adres":u 
        FIELD postnr      AS CHARACTER SERIALIZE-NAME "postnr":u 
        FIELD stad        AS CHARACTER SERIALIZE-NAME "stad":u 
        FIELD munt        AS CHARACTER SERIALIZE-NAME "munt":u 
        FIELD bedrag      AS DECIMAL   SERIALIZE-NAME "bedrag":u 
        FIELD btw         AS DECIMAL   SERIALIZE-NAME "btw":u 
        FIELD uRef        AS CHARACTER SERIALIZE-NAME "uRef":u 
        FIELD besteldatum AS DATE      SERIALIZE-NAME "besteldatum":u 
        FIELD levDatum    AS DATE      SERIALIZE-NAME "levDatum":u 
        FIELD geparkeerd  AS LOGICAL   SERIALIZE-NAME "geparkeerd":u 
        FIELD verzonden   AS LOGICAL   SERIALIZE-NAME "verzonden":u 
        FIELD opm         AS CHARACTER SERIALIZE-NAME "opm":u 
        FIELD recupelBedrag AS DECIMAL   SERIALIZE-NAME "recupelBedrag":u
        FIELD aBedrag       AS DECIMAL   SERIALIZE-NAME "aBedrag":u
        FIELD klnr2         AS INTEGER   SERIALIZE-NAME "klnr2":u
        FIELD klnr3         AS INTEGER   SERIALIZE-NAME "klnr3":u
        FIELD lnaam         AS CHARACTER SERIALIZE-NAME "lnaam":u
        FIELD lnaam1        AS CHARACTER SERIALIZE-NAME "lnaam1":u
        FIELD ladres        AS CHARACTER SERIALIZE-NAME "ladres":u
        FIELD lpostnr       AS CHARACTER SERIALIZE-NAME "lpostnr":u
        FIELD lstad         AS CHARACTER SERIALIZE-NAME "lstad":u
        INDEX idx-bonnr IS PRIMARY bonnr DESCENDING. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Copies the core subset of fields from a bon buffer into a 
                 ttBon row, for use by every read method below. 
    ------------------------------------------------------------------------------*/ 
    METHOD PRIVATE VOID CopyToTt( BUFFER pbBon FOR bon, BUFFER pbTt FOR ttBon ): 
 
        ASSIGN 
            pbTt.bonnr       = pbBon.bonnr 
            pbTt.type        = pbBon.type 
            pbTt.stempel     = pbBon.stempel 
            pbTt.datum       = pbBon.datum 
            pbTt.klnr        = pbBon.klnr 
            pbTt.naam        = pbBon.naam 
            pbTt.adres       = pbBon.adres 
            pbTt.postnr      = pbBon.postnr 
            pbTt.stad        = pbBon.stad 
            pbTt.munt        = pbBon.munt 
            pbTt.bedrag      = pbBon.b-bedrag 
            pbTt.btw         = pbBon.tot-btw 
            pbTt.uRef        = pbBon.u-ref 
            pbTt.besteldatum = pbBon.bestel-datum 
            pbTt.levDatum    = pbBon.lev-dat 
            pbTt.geparkeerd  = pbBon.geparkeerd 
            pbTt.verzonden   = pbBon.verzonden 
            pbTt.opm         = pbBon.opm 
            pbTt.recupelBedrag = pbBon.recupel-bedrag
            pbTt.aBedrag       = pbBon.a-bedrag
            pbTt.klnr2         = pbBon.klnr2
            pbTt.klnr3         = pbBon.klnr3
            pbTt.lnaam         = pbBon.lnaam
            pbTt.lnaam1        = pbBon.lnaam1
            pbTt.ladres        = pbBon.ladres
            pbTt.lpostnr       = pbBon.lpostnr
            pbTt.lstad         = pbBon.lstad
            . 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Returns a page of bon rows (newest bonnr first), optionally 
                 filtered by klnr (exact), type (exact), bonnr (prefix match) 
                 and naam (substring match, case-insensitive). 
        Notes  : NO-LOCK read-only. piPage/piPageSize are expected to already be 
                 validated/clamped by the caller (page >= 1, 1 <= pageSize <= 200). 
                 Same approach as Luna.BusinessLogic.OfferteBE:GetOffertes() - 
                 this deliberately does NOT compute an exact total count, 
                 instead it stops scanning as soon as it has one extra row 
                 beyond the requested page and reports that via plHasMore. 
                 klnr uses the existing bon-x3 index; a type/bonnr/naam-only 
                 filter scans every candidate row and should be combined with 
                 klnr where possible. 
                 pcVerzonden (added 2026-09-01 for Luna.BusinessLogic.AiSearchBE -
                 the "orders in productie" AI-search example needs geparkeerd
                 EQ false AND verzonden EQ false, mirroring the existing
                 pcGeparkeerd tri-state filter): "":u/"true":u/"false":u, same
                 convention as pcGeparkeerd. Luna.Web.BonHandler passes "":u
                 (no ?verzonden= query param wired yet - AiSearchBE is the
                 only caller today).
    ------------------------------------------------------------------------------*/ 
    METHOD PUBLIC HANDLE GetBonnen( 
        INPUT  piKlnr       AS INTEGER, 
        INPUT  pcType       AS CHARACTER, 
        INPUT  pcBonnr      AS CHARACTER, 
        INPUT  pcNaam       AS CHARACTER, 
        INPUT  piPage       AS INTEGER, 
        INPUT  piPageSize   AS INTEGER, 
        INPUT  pcGeparkeerd AS CHARACTER, 
        INPUT  pcVerzonden  AS CHARACTER, 
        OUTPUT plHasMore    AS LOGICAL ): 
 
        DEFINE VARIABLE iSkip  AS INTEGER NO-UNDO. 
        DEFINE VARIABLE iSeen  AS INTEGER NO-UNDO. 
        DEFINE VARIABLE iTaken AS INTEGER NO-UNDO. 
 
        EMPTY TEMP-TABLE ttBon. 
 
        ASSIGN 
            pcType       = TRIM(pcType) 
            pcBonnr      = TRIM(pcBonnr) 
            pcNaam       = UPPER(TRIM(pcNaam)) 
            pcGeparkeerd = TRIM(pcGeparkeerd) 
            pcVerzonden  = TRIM(pcVerzonden) 
            iSkip        = (piPage - 1) * piPageSize 
            iSeen        = 0 
            iTaken       = 0 
            plHasMore    = FALSE 
            . 
 
        FOR EACH bon NO-LOCK 
            WHERE (piKlnr LE 0 OR bon.klnr EQ piKlnr) 
              AND (pcType  EQ "":u OR bon.type EQ pcType) 
              AND (pcBonnr EQ "":u OR STRING(bon.bonnr) BEGINS pcBonnr) 
              AND (pcNaam  EQ "":u OR INDEX(UPPER(bon.naam), pcNaam) GT 0) 
              AND (pcGeparkeerd EQ "":u
                   OR (pcGeparkeerd EQ "true":u AND bon.geparkeerd)
                   OR (pcGeparkeerd EQ "false":u AND NOT bon.geparkeerd)) 
              AND (pcVerzonden EQ "":u
                   OR (pcVerzonden EQ "true":u AND bon.verzonden)
                   OR (pcVerzonden EQ "false":u AND NOT bon.verzonden))
            BY bon.bonnr DESCENDING: 
 
            iSeen = iSeen + 1. 
 
            IF iSeen LE iSkip THEN NEXT. 
 
            IF iTaken GE piPageSize THEN 
            DO: 
                plHasMore = TRUE. 
                LEAVE. 
            END. 
 
            CREATE ttBon. 
            CopyToTt( BUFFER bon, BUFFER ttBon ). 
            iTaken = iTaken + 1. 
        END. 
 
        RETURN TEMP-TABLE ttBon:HANDLE. 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------
        Purpose: Applies every field present in the JSON request body onto the
                 given `bon` buffer. Fields absent from the body are left
                 untouched, so this also works for partial updates. `bonnr`,
                 `bedrag` (b-bedrag) and `btw` (tot-btw) are never touched here -
                 bonnr is set once on create by CreateBon and is immutable,
                 bedrag/btw are computed totals owned by the order-lines
                 feature and are not settable via this API.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ApplyFields( INPUT poBody AS JsonObject, BUFFER pbBon FOR bon ):

        IF poBody:Has("type":u)        THEN pbBon.type         = poBody:GetCharacter("type":u).
        IF poBody:Has("stempel":u)     THEN pbBon.stempel      = poBody:GetCharacter("stempel":u).
        IF poBody:Has("datum":u)       THEN pbBon.datum        = poBody:GetDate("datum":u).
        IF poBody:Has("klnr":u)        THEN pbBon.klnr         = poBody:GetInteger("klnr":u).
        IF poBody:Has("naam":u)        THEN pbBon.naam         = poBody:GetCharacter("naam":u).
        IF poBody:Has("adres":u)       THEN pbBon.adres        = poBody:GetCharacter("adres":u).
        IF poBody:Has("postnr":u)      THEN pbBon.postnr       = poBody:GetCharacter("postnr":u).
        IF poBody:Has("stad":u)        THEN pbBon.stad         = poBody:GetCharacter("stad":u).
        IF poBody:Has("munt":u)        THEN pbBon.munt         = poBody:GetCharacter("munt":u).
        IF poBody:Has("uRef":u)        THEN pbBon.u-ref        = poBody:GetCharacter("uRef":u).
        IF poBody:Has("besteldatum":u) THEN pbBon.bestel-datum = poBody:GetDate("besteldatum":u).
        IF poBody:Has("levDatum":u)    THEN pbBon.lev-dat      = poBody:GetDate("levDatum":u).
        IF poBody:Has("geparkeerd":u)  THEN pbBon.geparkeerd   = poBody:GetLogical("geparkeerd":u).
        IF poBody:Has("verzonden":u)   THEN pbBon.verzonden    = poBody:GetLogical("verzonden":u).
        IF poBody:Has("opm":u)         THEN pbBon.opm          = poBody:GetCharacter("opm":u).
        IF poBody:Has("recupelBedrag":u) THEN pbBon.recupel-bedrag = poBody:GetDecimal("recupelBedrag":u).
        IF poBody:Has("aBedrag":u)       THEN pbBon.a-bedrag       = poBody:GetDecimal("aBedrag":u).
        IF poBody:Has("klnr2":u)         THEN pbBon.klnr2          = poBody:GetInteger("klnr2":u).
        IF poBody:Has("klnr3":u)         THEN pbBon.klnr3          = poBody:GetInteger("klnr3":u).
        IF poBody:Has("lnaam":u)         THEN pbBon.lnaam          = poBody:GetCharacter("lnaam":u).
        IF poBody:Has("lnaam1":u)        THEN pbBon.lnaam1         = poBody:GetCharacter("lnaam1":u).
        IF poBody:Has("ladres":u)        THEN pbBon.ladres         = poBody:GetCharacter("ladres":u).
        IF poBody:Has("lpostnr":u)       THEN pbBon.lpostnr        = poBody:GetCharacter("lpostnr":u).
        IF poBody:Has("lstad":u)         THEN pbBon.lstad          = poBody:GetCharacter("lstad":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns a single bon by bonnr, or an empty ttBon if it doesn't
                 exist (the WebHandler turns that into a 404).
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetBon( INPUT piBonnr AS INTEGER ):

        EMPTY TEMP-TABLE ttBon.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.

        IF AVAILABLE bon THEN
        DO:
            CREATE ttBon.
            CopyToTt( BUFFER bon, BUFFER ttBon ).
        END.

        RETURN TEMP-TABLE ttBon:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Creates a new bon. `bonnr` is computed server-side as
                 (last bonnr, via the bon-x1 index) + 1, held under the same
                 EXCLUSIVE-LOCK/transaction as the CREATE so there is no race
                 between the FIND LAST and the CREATE. `bonnr`, `bedrag` and
                 `btw` in the request body (if any) are ignored - see
                 ApplyFields.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE CreateBon( INPUT poBody AS JsonObject ):

        DEFINE VARIABLE iNewBonnr AS INTEGER NO-UNDO.

        EMPTY TEMP-TABLE ttBon.

        DO TRANSACTION:
            FIND LAST bon USE-INDEX bon-x1 EXCLUSIVE-LOCK NO-ERROR.

            iNewBonnr = (IF AVAILABLE bon THEN bon.bonnr ELSE 0) + 1.

            CREATE bon.
            ASSIGN bon.bonnr = iNewBonnr.

            /* TODO: klant.besteld update bij order-aanmaak - formule nog te
               bevestigen, zie architect-ontwerp Orders-iteratie-1. */

            ApplyFields( INPUT poBody, BUFFER bon ).

            CREATE ttBon.
            CopyToTt( BUFFER bon, BUFFER ttBon ).
        END.

        RETURN TEMP-TABLE ttBon:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Updates an existing bon. Only fields present in the JSON body
                 are changed (partial update); `bonnr`/`bedrag`/`btw` are never
                 written here - see ApplyFields.
        Errors : AppError code 404 - bonnr not found.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE UpdateBon( INPUT piBonnr AS INTEGER, INPUT poBody AS JsonObject ):

        EMPTY TEMP-TABLE ttBon.

        DO TRANSACTION:
            FIND FIRST bon EXCLUSIVE-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
            IF NOT AVAILABLE bon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

            ApplyFields( INPUT poBody, BUFFER bon ).

            CREATE ttBon.
            CopyToTt( BUFFER bon, BUFFER ttBon ).
        END.

        RETURN TEMP-TABLE ttBon:HANDLE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Checks whether any child rows exist for the given bonnr across
                 all order-line/related tables, short-circuiting on the first
                 hit. Used by DeleteBon to block deletion of orders that still
                 have related records.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL HasChildRows( INPUT piBonnr AS INTEGER ):

        IF CAN-FIND(FIRST bonlijn           NO-LOCK WHERE bonlijn.bonnr           EQ piBonnr) THEN RETURN TRUE.
        IF CAN-FIND(FIRST bonlijn_productie NO-LOCK WHERE bonlijn_productie.bonnr EQ piBonnr) THEN RETURN TRUE.
        IF CAN-FIND(FIRST bonlijn_variabel  NO-LOCK WHERE bonlijn_variabel.bonnr  EQ piBonnr) THEN RETURN TRUE.
        IF CAN-FIND(FIRST bon_herstel       NO-LOCK WHERE bon_herstel.bonnr       EQ piBonnr) THEN RETURN TRUE.
        IF CAN-FIND(FIRST bon_led           NO-LOCK WHERE bon_led.bonnr           EQ piBonnr) THEN RETURN TRUE.
        IF CAN-FIND(FIRST bon_led_qc        NO-LOCK WHERE bon_led_qc.bonnr        EQ piBonnr) THEN RETURN TRUE.

        RETURN FALSE.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Checks whether any bonlijn row for this bonnr still has an
                 outstanding order-with-supplier quantity (besteld <> 0).
                 Used by DeleteBon to block deletion in that case.
        Notes  : NOTE - in this iteration, HasChildRows() already blocks any
                 delete as long as bonlijn rows exist for this bonnr, so this
                 particular guard is currently unreachable in practice (a bon
                 with bonlijn.besteld <> 0 by definition has bonlijn rows).
                 It's added now per the approved design anyway, since
                 HasChildRows' bonlijn check could change independently in a
                 future iteration. Deliberately NOT calling
                 ReleaseReservationsForBon from DeleteBon in this iteration -
                 see AnnuleerBon for that logic; wiring it into delete is out
                 of scope for now.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL HasOutstandingBestelling( INPUT piBonnr AS INTEGER ):

        RETURN CAN-FIND(FIRST bonlijn NO-LOCK WHERE bonlijn.bonnr EQ piBonnr AND bonlijn.besteld NE 0).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Deletes a bon by bonnr.
        Errors : AppError code 404 - bonnr not found.
                 AppError code 409 - related order lines/records exist, or
                 order lines with an outstanding besteld quantity exist.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC VOID DeleteBon( INPUT piBonnr AS INTEGER ):

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        IF HasChildRows(piBonnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bon &1 has related order lines/records and cannot be deleted":u, piBonnr), 409).

        IF HasOutstandingBestelling(piBonnr) THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bon &1 has order lines with besteld <> 0 and cannot be deleted":u, piBonnr), 409).

        DO TRANSACTION:
            FIND FIRST bon EXCLUSIVE-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
            IF NOT AVAILABLE bon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

            DELETE bon.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Converts an amount expressed in the order's own currency
                 (pcMunt) using the `munt` table's koers/afrond, mirroring
                 the legacy Bprijs.p routine. Returns 0 if the currency code
                 isn't found in `munt`.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE DECIMAL ConvertToOrderCurrency( INPUT pdBedrag AS DECIMAL, INPUT pcMunt AS CHARACTER ):

        FIND FIRST munt NO-LOCK WHERE munt.kode EQ pcMunt NO-ERROR.
        IF NOT AVAILABLE munt THEN
            RETURN 0.

        RETURN ROUND(pdBedrag * munt.koers, munt.afrond).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Releases BOM (artlijn) sub-component reservations for a
                 single cancelled bonlijn, 1-on-1 port of the legacy
                 annul-bon BOM walk (Bon.w, verified against the real
                 legacy source). Only reached for bonlijn.artnr rows whose
                 `artikel.soort` is TRUE (a "gemengd"/BOM article).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ReleaseBomReservations(
        BUFFER pbArtikel FOR artikel,
        BUFFER pbBonlijn FOR bonlijn,
        BUFFER pbBon     FOR bon ):

        DEFINE VARIABLE dOffAantal AS DECIMAL NO-UNDO.
        DEFINE BUFFER bfBonlijn  FOR bonlijn.
        DEFINE BUFFER bfArtikel  FOR artikel.
        DEFINE BUFFER bfArtlijn  FOR artlijn.
        DEFINE BUFFER bf2Artikel FOR artikel.

        IF pbBonlijn.groepnr NE 0 THEN
        DO:
            FIND FIRST bfBonlijn OF pbBon
                WHERE bfBonlijn.groepnr EQ pbBonlijn.groepnr
                  AND bfBonlijn.subtotaal NO-LOCK NO-ERROR.
            dOffAantal = (IF AVAILABLE bfBonlijn THEN bfBonlijn.off_aantal ELSE 1).
        END.
        ELSE dOffAantal = 1.
        IF dOffAantal = 0 THEN dOffAantal = 1.

        FOR EACH artlijn OF pbArtikel NO-LOCK:
            FIND FIRST bfArtikel WHERE bfArtikel.artnr EQ artlijn.l-artnr EXCLUSIVE-LOCK NO-ERROR.
            IF AVAILABLE bfArtikel AND bfArtikel.stock THEN
            DO:
                /* Clamped at 0 (MAX(0, ...)) rather than an unconditional
                   subtraction - added for Iteratie C (automatische
                   voorraadreservering, Luna.BusinessLogic.
                   BonLijnAutoReserveringBE). That feature can reserve LESS
                   than bonlijn.te-leveren when stock falls short at
                   create-time, so releasing the FULL te-leveren quantity
                   here (as the legacy annul-bon procedure always did,
                   since it assumed reservation always matched te-leveren)
                   can now push pbesteld-kl below 0 when cancelling a bon
                   that was originally created with a shortfall. This was
                   NOT a pre-existing clamp - do not assume it always
                   worked this way. */
                IF NOT bfArtikel.soort THEN
                    bfArtikel.pbesteld-kl = MAX(0, bfArtikel.pbesteld-kl -
                        (IF artlijn.swVast THEN (artlijn.aantal * dOffAantal)
                                           ELSE (pbBonlijn.te-leveren * artlijn.aantal))).
                ELSE
                DO:
                    bfArtikel.pbesteld-kl = MAX(0, bfArtikel.pbesteld-kl - (pbBonlijn.te-leveren * artlijn.aantal)).

                    FOR EACH bfArtlijn OF bfArtikel NO-LOCK:
                        FIND FIRST bf2Artikel WHERE bf2Artikel.artnr EQ bfArtlijn.l-artnr EXCLUSIVE-LOCK NO-ERROR.
                        IF AVAILABLE bf2Artikel AND bf2Artikel.stock THEN
                            bf2Artikel.pbesteld-kl = MAX(0, bf2Artikel.pbesteld-kl -
                                (IF bfArtlijn.swVast THEN (bfArtlijn.aantal * (artlijn.aantal * dOffAantal))
                                                     ELSE ((pbBonlijn.te-leveren * bfArtlijn.aantal) * artlijn.aantal))).
                        RELEASE bf2Artikel.
                    END.
                END.
            END.
            RELEASE bfArtikel.
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Releases artikel.besteld-kl (and, for BOM articles,
                 artlijn sub-component pbesteld-kl) reservations for every
                 non-deleted, non-hold bonlijn of the given bon, and
                 accumulates the net order value (pdWsNet) used afterwards
                 by UpdateKlantBesteld. 1-on-1 port of the legacy annul-bon
                 loop (Bon.w, lines 10455-10540, verified against the real
                 legacy source).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ReleaseReservationsForBon( BUFFER pbBon FOR bon, OUTPUT pdWsNet AS DECIMAL ):

        pdWsNet = 0.

        FOR EACH bonlijn OF pbBon
            WHERE bonlijn.stempel NE "D":u
              AND bonlijn.hold EQ FALSE NO-LOCK:

            FIND artikel EXCLUSIVE-LOCK WHERE artikel.artnr EQ bonlijn.artnr AND artikel.stock NO-ERROR.
            IF AVAILABLE artikel THEN
            DO:
                /* Clamped at 0 - see the comment in ReleaseBomReservations
                   above for why (Iteratie C automatische
                   voorraadreservering can reserve less than te-leveren on
                   a stock shortfall, so releasing the full te-leveren on
                   cancel could otherwise push besteld-kl below 0). */
                artikel.besteld-kl = MAX(0, artikel.besteld-kl - bonlijn.te-leveren).

                IF artikel.soort THEN
                    ReleaseBomReservations( BUFFER artikel, BUFFER bonlijn, BUFFER pbBon ).
            END.
            RELEASE artikel.

            pdWsNet = pdWsNet + (bonlijn.te-leveren * (bonlijn.vprijs * (1 - (bonlijn.korting / 100)))).
        END.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Reduces klant.besteld by the order value being released,
                 converted to the customer's/order's currency via
                 ConvertToOrderCurrency (legacy Bprijs.p equivalent).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID UpdateKlantBesteld( BUFFER pbBon FOR bon, INPUT pdWsNet AS DECIMAL ):

        DEFINE VARIABLE dWsBedrag AS DECIMAL NO-UNDO.

        FIND FIRST klant EXCLUSIVE-LOCK WHERE klant.klnr EQ pbBon.klnr NO-ERROR.
        IF AVAILABLE klant THEN
        DO:
            dWsBedrag = ConvertToOrderCurrency(pdWsNet, pbBon.munt).
            klant.besteld = klant.besteld - dWsBedrag.
        END.
        RELEASE klant.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Zeroes out the bon amount fields that the legacy annul-bon
                 procedure clears on cancellation. `bon.tot-btw` is
                 deliberately NOT touched - legacy annul-bon doesn't clear
                 it either, so the cancelled bon keeps showing its last BTW
                 total (legacy-consistent, not a bug).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ClearBedragVelden( BUFFER pbBon FOR bon ):

        ASSIGN
            pbBon.n-bedrag       = 0
            pbBon.recupel-bedrag = 0
            pbBon.b-bedrag       = 0
            pbBon.a-bedrag       = 0
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Cancels a bon: releases stock reservations (besteld-kl /
                 pbesteld-kl, incl. BOM sub-components), reduces
                 klant.besteld by the released order value, zeroes the bon
                 amount fields (except tot-btw) and sets stempel to "O".
                 1-on-1 port of the legacy annul-bon procedure (Bon.w),
                 verified against the real legacy source.
        Errors : AppError code 404 - bonnr not found.
                 AppError code 409 - bon.stempel is neither "V" nor "B".
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE AnnuleerBon( INPUT piBonnr AS INTEGER ):

        DEFINE VARIABLE dWsNet AS DECIMAL NO-UNDO.

        EMPTY TEMP-TABLE ttBon.

        FIND FIRST bon NO-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
        IF NOT AVAILABLE bon THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

        IF bon.stempel NE "V":u AND bon.stempel NE "B":u THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Bon &1 has stempel '&2' and cannot be cancelled (must be 'V' or 'B')":u,
                    piBonnr, bon.stempel), 409).

        DO TRANSACTION:
            FIND FIRST bon EXCLUSIVE-LOCK WHERE bon.bonnr EQ piBonnr NO-ERROR.
            IF NOT AVAILABLE bon THEN
                UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Bon &1 not found":u, piBonnr), 404).

            ClearBedragVelden( BUFFER bon ).
            ReleaseReservationsForBon( BUFFER bon, OUTPUT dWsNet ).
            UpdateKlantBesteld( BUFFER bon, INPUT dWsNet ).

            bon.stempel = "O":u.

            CREATE ttBon.
            CopyToTt( BUFFER bon, BUFFER ttBon ).
        END.

        RETURN TEMP-TABLE ttBon:HANDLE.

    END METHOD.

END CLASS. 
