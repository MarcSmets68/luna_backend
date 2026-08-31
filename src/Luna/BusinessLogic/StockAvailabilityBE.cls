/*------------------------------------------------------------------------
    File        : StockAvailabilityBE.cls
    Purpose     : Business Entity for the on-demand composiet-artikel
                  beschikbaarheidsberekening (FR-4, "Hoeveel kan ik nog
                  bouwen?" - CheckStock.p-equivalent). Deliberately a
                  separate class from Luna.BusinessLogic.ArtikelBE - this is
                  a BOM-doorloop over `artlijn`, not `artikel` CRUD, with its
                  own response shape (see docs/architecture/
                  voorraad-fase1-ontwerp.md §1.4/§2.2).
    Logica      : Voor artnr pcArtnr, per artlijn-component (l-artnr):
                    componentBeschikbaar = TRUNCATE(component.aantal / artlijn.aantal, 3)
                  (BR-5: puur artikel.aantal van het component, NIET
                  aantal-gereserveerd, om CheckStock.p's legacy-gedrag
                  1-op-1 te reproduceren). bouwbareEenheden = MIN over alle
                  componenten. Eén niveau diep, geen recursie (OV-7/§1.4) -
                  een component dat zelf een artlijn heeft, wordt genegeerd.
                  SIKTA led_montage-uitzondering (OV-4) NIET geimplementeerd
                  in Fase 1 - siktaUitzonderingToegepast staat altijd op
                  FALSE (OD-7, contractvorm alvast klaar voor later).
    Syntax      : Called from Luna.Web.ArtikelHandler (GET
                  /web/artikel/{artnr}/beschikbaarheid)
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK reads only
                  (read-only feature, no writes in Fase 1).
    Author(s)   : Devin
    Created     : 2026-08-21
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.StockAvailabilityBE:

    /* Explicit buffer alias for the component's `artikel` row - the main
       artikel (pcArtnr) and each of its artlijn components both live in
       the same `artikel` table, so a 2nd buffer is required to look up
       the component while the outer FOR EACH is still iterating artlijn. */
    DEFINE BUFFER component-artikel FOR artikel.

    /* Header/kop-resultaat - single row, SERIALIZE-NAME "beschikbaarheid"
       zodat de WebHandler dit samen met de componenten-array tot één
       response-object combineert (analoog aan LakproductieBestellingBE's
       ttBestelling/ttBestellingLijn-paar). */
    DEFINE TEMP-TABLE ttBeschikbaarheid NO-UNDO SERIALIZE-NAME "beschikbaarheid":u
        FIELD artnr                      AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD isSamengesteld             AS LOGICAL   SERIALIZE-NAME "isSamengesteld":u
        FIELD bouwbareEenheden           AS DECIMAL   SERIALIZE-NAME "bouwbareEenheden":u
        FIELD siktaUitzonderingToegepast AS LOGICAL   SERIALIZE-NAME "siktaUitzonderingToegepast":u
        INDEX idx-artnr IS PRIMARY artnr.

    /* Component-detail resultaat - SERIALIZE-NAME "componenten". Het artnr
       veld hier is puur een interne join-sleutel (niet geserialiseerd -
       SERIALIZE-HIDDEN houdt het volledig uit de JSON-output, zie
       ontwerp §2.2). */
    DEFINE TEMP-TABLE ttBeschikbaarheidComponent NO-UNDO SERIALIZE-NAME "componenten":u
        FIELD artnr                   AS CHARACTER SERIALIZE-HIDDEN
        FIELD componentArtnr          AS CHARACTER SERIALIZE-NAME "componentArtnr":u
        FIELD componentOmschrijving   AS CHARACTER SERIALIZE-NAME "componentOmschrijving":u
        FIELD benodigdPerEenheid      AS DECIMAL   SERIALIZE-NAME "benodigdPerEenheid":u
        FIELD componentVoorraad       AS DECIMAL   SERIALIZE-NAME "componentVoorraad":u
        FIELD bouwbaarUitDitComponent AS DECIMAL   SERIALIZE-NAME "bouwbaarUitDitComponent":u
        FIELD isBottleneck            AS LOGICAL   SERIALIZE-NAME "isBottleneck":u
        INDEX idx-artnr artnr.

    /*------------------------------------------------------------------------------
        Purpose: Computes the composiet-beschikbaarheid for pcArtnr - one level
                 deep over `artlijn` components, no recursion (OV-7).
        Output : Returns the ttBeschikbaarheid handle (single header row);
                 phComponenten is set to the ttBeschikbaarheidComponent
                 handle (one row per artlijn component, empty if pcArtnr is
                 not a composiet artikel).
        Errors : AppError 404 - pcArtnr does not exist in `artikel`.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetBeschikbaarheid( INPUT pcArtnr AS CHARACTER, OUTPUT phComponenten AS HANDLE ):

        DEFINE VARIABLE dComponentBeschikbaar AS DECIMAL NO-UNDO.
        DEFINE VARIABLE dMinBouwbaar          AS DECIMAL NO-UNDO INITIAL ?.
        DEFINE VARIABLE lHeeftComponenten     AS LOGICAL NO-UNDO INITIAL FALSE.

        EMPTY TEMP-TABLE ttBeschikbaarheid.
        EMPTY TEMP-TABLE ttBeschikbaarheidComponent.

        FIND FIRST artikel NO-LOCK WHERE artikel.artnr EQ pcArtnr NO-ERROR.
        IF NOT AVAILABLE artikel THEN
            UNDO, THROW NEW Progress.Lang.AppError(SUBSTITUTE("Artikel &1 not found":u, pcArtnr), 404).

        /* artlijn-x1 (artnr, lijnnr) is a unique index - filtering on artnr
           is an indexed range scan, safe to do on-demand per artikel (see
           design §1.4 performance note). */
        FOR EACH artlijn NO-LOCK WHERE artlijn.artnr EQ pcArtnr:

            lHeeftComponenten = TRUE.

            FIND FIRST component-artikel NO-LOCK
                WHERE component-artikel.artnr EQ artlijn.l-artnr NO-ERROR.

            IF NOT AVAILABLE component-artikel OR artlijn.aantal EQ 0 THEN
                NEXT.

            /* BR-5: puur artikel.aantal van het component (niet aantal -
               gereserveerd) om CheckStock.p 1-op-1 te reproduceren. */
            dComponentBeschikbaar = TRUNCATE(component-artikel.aantal / artlijn.aantal, 3).

            IF dMinBouwbaar EQ ? OR dComponentBeschikbaar LT dMinBouwbaar THEN
                dMinBouwbaar = dComponentBeschikbaar.

            CREATE ttBeschikbaarheidComponent.
            ASSIGN
                ttBeschikbaarheidComponent.artnr                   = pcArtnr
                ttBeschikbaarheidComponent.componentArtnr          = component-artikel.artnr
                ttBeschikbaarheidComponent.componentOmschrijving   = component-artikel.omschr-n
                ttBeschikbaarheidComponent.benodigdPerEenheid      = artlijn.aantal
                ttBeschikbaarheidComponent.componentVoorraad       = component-artikel.aantal
                ttBeschikbaarheidComponent.bouwbaarUitDitComponent = dComponentBeschikbaar
                .
        END.

        /* isBottleneck = TRUE for every component whose own bouwbaar value
           equals the overall MIN - computed server-side in a 2nd pass so
           the frontend never has to compare/float itself (design §1.4). */
        IF dMinBouwbaar NE ? THEN
        DO:
            FOR EACH ttBeschikbaarheidComponent WHERE ttBeschikbaarheidComponent.artnr EQ pcArtnr:
                ttBeschikbaarheidComponent.isBottleneck = (ttBeschikbaarheidComponent.bouwbaarUitDitComponent EQ dMinBouwbaar).
            END.
        END.

        CREATE ttBeschikbaarheid.
        ASSIGN
            ttBeschikbaarheid.artnr                      = pcArtnr
            ttBeschikbaarheid.isSamengesteld              = lHeeftComponenten
            ttBeschikbaarheid.bouwbareEenheden            = dMinBouwbaar
            /* OD-7: SIKTA-uitzondering (OV-4) niet geimplementeerd in Fase 1 -
               dit veld staat vast op FALSE zodat het contract al klaar is. */
            ttBeschikbaarheid.siktaUitzonderingToegepast  = FALSE
            .

        phComponenten = TEMP-TABLE ttBeschikbaarheidComponent:HANDLE.
        RETURN TEMP-TABLE ttBeschikbaarheid:HANDLE.

    END METHOD.

END CLASS.
