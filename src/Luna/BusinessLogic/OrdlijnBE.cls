/*------------------------------------------------------------------------
    File        : OrdlijnBE.cls
    Purpose     : Business Entity for the "ordlijn" (purchase order line)
                  table - read-only access to a curated core subset of
                  fields (identification, article, quantities, pricing,
                  status, customer-order link). `ordlijn` is a child of
                  `order` (linked via ordnr) - see
                  Luna.BusinessLogic.BestelorderBE for the parent. The
                  `ordlijn` table has ~39 fields in total; only the subset
                  below is exposed via the API for now.
    Field map (JSON key -> ordlijn column):
                  ordnr        -> ordnr
                  lijnnr       -> lijnnr
                  artnr        -> artnr
                  omschrijving -> omschr
                  aantal       -> aantal
                  teLeveren    -> te-leveren
                  vprijs       -> vprijs
                  korting      -> korting
                  btwKode      -> btw-kode
                  bedrag       -> bedrag
                  stempel      -> stempel      (raw code, no label mapping)
                  levnr        -> levnr
                  levDatum     -> lev-dat
                  bonnr        -> bonnr        (link to customer order, if any)
                  blijnnr      -> blijnnr
                  volgnr       -> volgnr
                  opm          -> opm
    Syntax      : Called from Luna.Web.BestelorderHandler (GET
                  /web/bestelorder/{ordnr}/lijn)
    Description : Owns all DB access for this feature - no direct DB access
                  is allowed from the WebHandler layer. NO-LOCK for reads.
                  Read-only: no Create/Update/Delete methods exist on this
                  class, same as Luna.BusinessLogic.BestelorderBE - that is
                  intentional, not an oversight. Deliberately does not
                  validate that the parent ordnr exists - it just returns
                  every ordlijn row matching that ordnr (empty if there are
                  none, whether because the order doesn't exist or it has
                  no lines). Callers that need a 404 for a missing order
                  should check GET /web/bestelorder/{ordnr} first.
    Author(s)   : Devin
    Created     : 2026-08-18
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.OrdlijnBE:

    /* Result shape returned to the WebHandler. SERIALIZE-NAME controls the
       JSON array key so list responses read as {"items": [...]}. */
    DEFINE TEMP-TABLE ttOrdlijn NO-UNDO SERIALIZE-NAME "items":u
        FIELD ordnr        AS INTEGER   SERIALIZE-NAME "ordnr":u
        FIELD lijnnr       AS INTEGER   SERIALIZE-NAME "lijnnr":u
        FIELD artnr        AS CHARACTER SERIALIZE-NAME "artnr":u
        FIELD omschrijving AS CHARACTER SERIALIZE-NAME "omschrijving":u
        FIELD aantal       AS DECIMAL   SERIALIZE-NAME "aantal":u
        FIELD teLeveren    AS DECIMAL   SERIALIZE-NAME "teLeveren":u
        FIELD vprijs       AS DECIMAL   SERIALIZE-NAME "vprijs":u
        FIELD korting      AS DECIMAL   SERIALIZE-NAME "korting":u
        FIELD btwKode      AS CHARACTER SERIALIZE-NAME "btwKode":u
        FIELD bedrag       AS DECIMAL   SERIALIZE-NAME "bedrag":u
        FIELD stempel      AS CHARACTER SERIALIZE-NAME "stempel":u
        FIELD levnr        AS INTEGER   SERIALIZE-NAME "levnr":u
        FIELD levDatum     AS DATE      SERIALIZE-NAME "levDatum":u
        FIELD bonnr        AS INTEGER   SERIALIZE-NAME "bonnr":u
        FIELD blijnnr      AS INTEGER   SERIALIZE-NAME "blijnnr":u
        FIELD volgnr       AS INTEGER   SERIALIZE-NAME "volgnr":u
        FIELD opm          AS CHARACTER SERIALIZE-NAME "opm":u
        INDEX idx-lijnnr IS PRIMARY ordnr lijnnr.

    /*------------------------------------------------------------------------------
        Purpose: Copies the core subset of fields from an `ordlijn` buffer
                 into a ttOrdlijn row, for use by every read method below.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID CopyToTt( BUFFER pbOrdlijn FOR ordlijn, BUFFER pbTt FOR ttOrdlijn ):

        ASSIGN
            pbTt.ordnr        = pbOrdlijn.ordnr
            pbTt.lijnnr       = pbOrdlijn.lijnnr
            pbTt.artnr        = pbOrdlijn.artnr
            pbTt.omschrijving = pbOrdlijn.omschr
            pbTt.aantal       = pbOrdlijn.aantal
            pbTt.teLeveren    = pbOrdlijn.te-leveren
            pbTt.vprijs       = pbOrdlijn.vprijs
            pbTt.korting      = pbOrdlijn.korting
            pbTt.btwKode      = pbOrdlijn.btw-kode
            pbTt.bedrag       = pbOrdlijn.bedrag
            pbTt.stempel      = pbOrdlijn.stempel
            pbTt.levnr        = pbOrdlijn.levnr
            pbTt.levDatum     = pbOrdlijn.lev-dat
            pbTt.bonnr        = pbOrdlijn.bonnr
            pbTt.blijnnr      = pbOrdlijn.blijnnr
            pbTt.volgnr       = pbOrdlijn.volgnr
            pbTt.opm          = pbOrdlijn.opm
            .

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Returns every ordlijn row for the given ordnr, ordered by
                 lijnnr.
        Notes  : NO-LOCK read-only. Uses the ordlijn-x1 (unique) index. Does
                 not validate that the parent order exists - see class
                 header.
    ------------------------------------------------------------------------------*/
    METHOD PUBLIC HANDLE GetOrdlijnen( INPUT piOrdnr AS INTEGER ):

        EMPTY TEMP-TABLE ttOrdlijn.

        FOR EACH ordlijn NO-LOCK
            WHERE ordlijn.ordnr EQ piOrdnr
            BY ordlijn.lijnnr:

            CREATE ttOrdlijn.
            CopyToTt( BUFFER ordlijn, BUFFER ttOrdlijn ).
        END.

        RETURN TEMP-TABLE ttOrdlijn:HANDLE.

    END METHOD.

END CLASS.
