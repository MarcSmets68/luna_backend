/*------------------------------------------------------------------------
    File        : BestelorderHandler.cls
    Purpose     : WebHandler exposing read-only access to the "order"
                  table (purchase orders to suppliers/leveranciers) -
                  core field subset, see Luna.BusinessLogic.BestelorderBE
                  for the field map - plus its nested read-only `ordlijn`
                  (purchase order line) rows, see
                  Luna.BusinessLogic.OrdlijnBE for that field map. Named
                  "Bestelorder" rather than "Order" to avoid the ABL/SQL-
                  reserved word ORDER and to avoid confusion with the
                  existing `bon`-based "Orders & Productie" feature
                  (customer sales orders, a different table).
    Syntax      : GET /web/bestelorder                 - list (paged/filtered)
                  GET /web/bestelorder/{ordnr}          - get one
                  GET /web/bestelorder/{ordnr}/lijn     - list ordlijn for this order
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.BestelorderBE / Luna.BusinessLogic.OrdlijnBE.
                  Read-only: no POST/PUT/DELETE routes on this handler.
    Author(s)   : Devin
    Created     : 2026-08-12
    Updated     : 2026-08-18 - added nested read-only ordlijn listing
                  (.../{ordnr}/lijn) for the "Detail bestelling" feature.
    Updated     : 2026-08-18 - added ordnr/naam filtering and sortField/
                  sortDir sorting query params to GET /bestelorder, for
                  the "filters en sortering voor bestellingen" feature.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.BestelorderBE.
USING Luna.BusinessLogic.OrdlijnBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.BestelorderHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/bestelorder" with the
       implicit trailing wildcard, so this also matches
       "/bestelorder/{ordnr}" and "/bestelorder/{ordnr}/lijn". This
       constant is the mount point we strip off PathInfo to find the
       remaining path segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/bestelorder":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount
                 point, e.g. "/bestelorder/123" -> "123",
                 "/bestelorder/123/lijn" -> "123/lijn",
                 "/bestelorder" or "/bestelorder/" -> "".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        cRest = TRIM(cRest, "/":u).

        RETURN cRest.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Number of "/"-separated segments in the path remainder ("" -> 0).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER SegmentCount( INPUT pcRemainder AS CHARACTER ):

        IF pcRemainder EQ "":u THEN
            RETURN 0.

        RETURN NUM-ENTRIES(pcRemainder, "/":u).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Validates that the 2nd path segment (if present) is the
                 literal "lijn" - the only nested resource under
                 bestelorder.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE LOGICAL IsLijnSegment( INPUT pcRemainder AS CHARACTER ):

        RETURN ENTRY(2, pcRemainder, "/":u) EQ "lijn":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Normalizes the "sortField" query param to one of
                 "ordnr"/"datum"/"naam"/"stempel" - any absent/unknown
                 value falls back to "ordnr" (same as BestelorderBE's own
                 fallback, kept here too so the {"sortField": ...} the
                 caller gets back in a future echo always reflects what
                 was actually applied).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER NormalizeSortField( INPUT pcSortField AS CHARACTER ):

        IF LOOKUP(pcSortField, "ordnr,datum,naam,stempel":u) EQ 0 THEN
            RETURN "ordnr":u.

        RETURN pcSortField.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Normalizes the "sortDir" query param to "asc" or "desc" -
                 any absent/unknown value falls back to "desc".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER NormalizeSortDir( INPUT pcSortDir AS CHARACTER ):

        IF pcSortDir EQ "asc":u THEN
            RETURN "asc":u.

        RETURN "desc":u.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes a ttBestelorder/ttOrdlijn result handle (from
                 BestelorderBE/OrdlijnBE) to a JsonObject shaped as
                 {"items": [...]}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR         NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON response with the given status code.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteJsonResponse( INPUT piStatusCode AS INTEGER, INPUT poBody AS JsonObject ):

        DEFINE VARIABLE oResponse AS OpenEdge.Net.HTTP.IHttpResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter               NO-UNDO.

        ASSIGN
            oResponse             = NEW OpenEdge.Web.WebResponse()
            oResponse:StatusCode  = piStatusCode
            oResponse:Entity      = poBody
            oResponse:ContentType = "application/json":u
            .

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Writes a JSON error response: {"error": {"message": "...", "code": n}}.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID WriteErrorResponse( INPUT piStatusCode AS INTEGER, INPUT pcMessage AS CHARACTER ):

        DEFINE VARIABLE oError AS JsonObject NO-UNDO.
        DEFINE VARIABLE oBody  AS JsonObject NO-UNDO.

        oError = NEW JsonObject().
        oError:Add("message":u, pcMessage).
        oError:Add("code":u, piStatusCode).

        oBody = NEW JsonObject().
        oBody:Add("error":u, oError).

        WriteJsonResponse(piStatusCode, oBody).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /bestelorder (list, paged/filtered),
                 GET /bestelorder/{ordnr} (single record) and
                 GET /bestelorder/{ordnr}/lijn (list ordlijn for that
                 order). Invalid/non-numeric levnr, page, pageSize or
                 {ordnr} are not rejected with 400 - they silently fall
                 back to "no filter"/default page/pageSize, or (for
                 {ordnr}) to a value that will not match any row and
                 therefore surfaces as a normal 404 (or an empty "items"
                 list for .../lijn). Same approach as /web/klant and
                 /web/offerte.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService   AS BestelorderBE NO-UNDO.
        DEFINE VARIABLE oOrdlijnBE AS OrdlijnBE      NO-UNDO.
        DEFINE VARIABLE cRemainder AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iSegCount  AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cOrdnr     AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iOrdnr     AS INTEGER        NO-UNDO.
        DEFINE VARIABLE hResult    AS HANDLE         NO-UNDO.
        DEFINE VARIABLE oBody      AS JsonObject     NO-UNDO.
        DEFINE VARIABLE oItems     AS JsonArray      NO-UNDO.
        DEFINE VARIABLE iLevnr     AS INTEGER        NO-UNDO.
        DEFINE VARIABLE cOrdnrFilter AS CHARACTER    NO-UNDO.
        DEFINE VARIABLE cNaam      AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cSortField AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE cSortDir   AS CHARACTER      NO-UNDO.
        DEFINE VARIABLE iPage      AS INTEGER        NO-UNDO.
        DEFINE VARIABLE iPageSize  AS INTEGER        NO-UNDO.
        DEFINE VARIABLE lHasMore   AS LOGICAL        NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oService   = NEW BestelorderBE().
        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 2 THEN
        DO:
            /* GET /bestelorder/{ordnr}/lijn */
            IF iSegCount NE 2 OR NOT IsLijnSegment(cRemainder) THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /bestelorder/[ordnr]/lijn, got &1":u, cRemainder)).
                RETURN 0.
            END.

            cOrdnr = ENTRY(1, cRemainder, "/":u).
            iOrdnr = INTEGER(cOrdnr) NO-ERROR.
            IF iOrdnr EQ ? THEN iOrdnr = 0.

            oOrdlijnBE = NEW OrdlijnBE().
            hResult    = oOrdlijnBE:GetOrdlijnen(iOrdnr).
            oBody      = ResultHandleToJson(hResult).

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

            RETURN 0.
        END.

        cOrdnr = cRemainder.

        IF cOrdnr NE "":u THEN
        DO:
            /* GET /bestelorder/{ordnr} */
            iOrdnr = INTEGER(cOrdnr) NO-ERROR.
            IF iOrdnr EQ ? THEN iOrdnr = 0.

            hResult = oService:GetBestelorder(iOrdnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Bestelorder &1 not found":u, cOrdnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /bestelorder (list). GetQueryValue returns the unknown
           value (?) when a query param is absent - normalize/clamp so
           BestelorderBE always gets valid inputs. */
        iLevnr = INTEGER(poRequest:URI:GetQueryValue("levnr":u)) NO-ERROR.
        IF iLevnr EQ ? THEN iLevnr = 0.

        cOrdnrFilter = poRequest:URI:GetQueryValue("ordnr":u).
        IF cOrdnrFilter EQ ? THEN cOrdnrFilter = "":u.

        cNaam = poRequest:URI:GetQueryValue("naam":u).
        IF cNaam EQ ? THEN cNaam = "":u.

        cSortField = NormalizeSortField(poRequest:URI:GetQueryValue("sortField":u)).
        cSortDir   = NormalizeSortDir(poRequest:URI:GetQueryValue("sortDir":u)).

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        hResult = oService:GetBestelorders(iLevnr, cOrdnrFilter, cNaam, cSortField, cSortDir, iPage, iPageSize, OUTPUT lHasMore).
        oBody   = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).
        oBody:Add("sortField":u, cSortField).
        oBody:Add("sortDir":u, cSortDir).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /bestelorder":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /bestelorder":u).
        RETURN 0.
    END METHOD.

END CLASS.
