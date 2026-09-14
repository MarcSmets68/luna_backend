/*------------------------------------------------------------------------
    File        : ArtikelHandler.cls
    Purpose     : WebHandler exposing full CRUD for the "artikel" table
                  (core field subset - see Luna.BusinessLogic.ArtikelBE for
                  the field map), plus two read-only Fase 1 sub-resources
                  nested under it (see docs/architecture/
                  voorraad-fase1-ontwerp.md).
    Syntax      : GET    /web/artikel                          - list (paged/filtered)
                  GET    /web/artikel/{artnr}                  - get one
                  POST   /web/artikel                          - create
                  PUT    /web/artikel/{artnr}                  - update
                         /web/artikel?artnr={artnr}             - update (fallback
                         for artnr values that break the path form, e.g. "%")
                  DELETE /web/artikel/{artnr}                  - delete
                         /web/artikel?artnr={artnr}             - delete (same
                         query-param fallback as PUT)
                  GET    /web/artikel/{artnr}/beschikbaarheid  - composiet-beschikbaarheid (FR-4)
                  GET    /web/artikel/{artnr}/artlog           - bewegingshistoriek, gepagineerd (FR-5)

                  GET /web/artikel supports optional
                  ?onderMinimum=intern|extern|beide and
                  ?externInBewerking=true|false filters alongside the
                  existing artnr/omschrijving/groep/page/pageSize ones, plus
                  ?lageVoorraad=true|false. lageVoorraad is EXCLUSIVE: when
                  true, all other list filters (artnr/omschrijving/groep/
                  onderMinimum/externInBewerking) are ignored, not combined
                  and not validated.
    Description : Thin WebHandler only - routing, request parsing, response
                  formatting and HTTP status/error mapping. No business logic
                  and no direct DB access - all of that lives in
                  Luna.BusinessLogic.ArtikelBE (artikel),
                  Luna.BusinessLogic.StockAvailabilityBE (beschikbaarheid)
                  and Luna.BusinessLogic.ArtlogBE (artlog). Path parsing for
                  the nested sub-resources follows the
                  GetPathRemainder/SegmentCount pattern from
                  Luna.Web.BonHandler.
    Author(s)   : Devin
    Created     : 2026-08-10
    Updated     : 2026-08-21 - added /beschikbaarheid and /artlog
                  sub-resources + onderMinimum/externInBewerking list
                  filters (voorraad-fase1-ontwerp.md).
                  2026-08-22 - PUT now also accepts artnr as a query param
                  (?artnr=...) as a fallback when the path segment is
                  missing/empty, for artnr values containing characters
                  (e.g. "%") that PASOE/Tomcat mis-route as a URL path
                  segment.
                  2026-08-27 - DELETE now also accepts the same
                  ?artnr=... query-param fallback as PUT. All query-param
                  reads (artnr/omschrijving/groep/onderMinimum/
                  externInBewerking/page/pageSize on the list, and
                  datumVan/datumTot/beweging/page/pageSize on /artlog) now
                  go through Luna.Web.Util.QueryParamHelper instead of
                  poRequest:URI:GetQueryValue() directly - the latter
                  percent-decodes twice (once when the framework builds
                  its internal QueryString, once again inside
                  GetQueryValue() itself), which silently mangled artnr
                  values containing a literal "%" encoded the standard
                  way (single encoding, e.g. "%25" for a literal "%").
                  QueryParamHelper parses the singly-decoded
                  URI:QueryString itself instead, fixing this for both the
                  PUT/DELETE query fallback and the existing GET
                  ?artnr=... filter (see docs/backend/artikel.md).
                  2026-08-29 - added ?lageVoorraad=true|false to the GET
                  list filter (exclusive with the other list filters - see
                  Syntax above and Luna.BusinessLogic.ArtikelBE.
                  GetArtikelen).
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.ArtikelBE.
USING Luna.BusinessLogic.StockAvailabilityBE.
USING Luna.BusinessLogic.ArtlogBE.
USING Luna.Web.Util.QueryParamHelper.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.ArtikelHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/artikel" with the implicit
       trailing wildcard, so this also matches every nested path below it
       too (artnr and artnr/beschikbaarheid, artnr/artlog). This constant
       is the mount point we strip off PathInfo to find the remaining path
       segments. */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/artikel":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the artnr path segment (if any) from the request, e.g.
                 "/artikel/AB123" -> "AB123", "/artikel" or "/artikel/" -> "".
        Notes  : Used by Put/Delete (single-segment paths only). GET uses
                 GetPathRemainder/SegmentCount below to also support the
                 nested sub-resources.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetArtnrFromPath( INPUT poRequest AS IWebRequest ):

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
        Purpose: Extracts the artnr for PUT/DELETE, preferring the URL path
                 segment (as GetArtnrFromPath does) but falling back to the
                 "artnr" query param when the path segment is absent - same
                 fallback GET already relies on (via
                 QueryParamHelper:GetQueryValue("artnr")) for artnr values
                 that don't survive PASOE/Tomcat's path routing/encoding,
                 e.g. artnr containing "%".
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE CHARACTER GetArtnrFromPathOrQuery( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cArtnr AS CHARACTER NO-UNDO.

        cArtnr = GetArtnrFromPath(poRequest).

        IF cArtnr EQ "":u THEN
            cArtnr = QueryParamHelper:GetQueryValue(poRequest, "artnr":u).

        RETURN cArtnr.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segments (if any) after the mount point,
                 e.g. "/artikel/AB123" -> "AB123",
                 "/artikel/AB123/artlog" -> "AB123/artlog",
                 "/artikel" or "/artikel/" -> "".
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
        Purpose: Validates that the 2nd path segment is one of the known
                 sub-resource literals ("beschikbaarheid" or "artlog").
        Errors : Throws AppError 400 if it isn't.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID ValidateSubResourceSegment( INPUT pcRemainder AS CHARACTER ):

        IF LOOKUP(ENTRY(2, pcRemainder, "/":u), "beschikbaarheid,artlog":u) EQ 0 THEN
            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Expected /artikel/[artnr]/beschikbaarheid or /artikel/[artnr]/artlog, got &1":u, pcRemainder), 400).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Parses the request body entity into a JsonObject.
        Errors : Throws AppError 400 if the body is missing or not a JSON object.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            /* poRequest:Entity lazily deserializes the raw request body the
               first time it's accessed, right here. A malformed body (e.g.
               a stray UTF-8 BOM prepended by some HTTP clients/tools before
               the JSON, or plain invalid JSON) makes the underlying
               OpenEdge JSON parser throw a non-AppError (a JSON parser
               lexical error) - uncaught, that used to escape this method
               entirely, bypass the calling method's own
               "CATCH ... AS Progress.Lang.AppError", and reach PASOE's
               generic framework error handler, producing a raw 500 (HTML,
               or a JSON envelope with empty exception fields) instead of
               the documented 400. Re-throw AppErrors as-is (e.g. the
               "must be a JSON object" one above); convert anything else
               (the JSON parser error case) into a clean AppError 400 here
               so it's mapped the same as any other bad request. */
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Serializes a ttArtikel result handle (from ArtikelBE) to a
                 JsonObject shaped as {"items": [...]}.
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
        Purpose: Maps an AppError raised by ArtikelBE (400/404/409) to an HTTP
                 status code, defaulting unrecognized codes to 500 so no ABL
                 stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /artikel (list, paged/filtered), GET /artikel/{artnr}
                 (single record), GET /artikel/{artnr}/beschikbaarheid
                 (FR-4, composiet-beschikbaarheid) and GET
                 /artikel/{artnr}/artlog (FR-5, bewegingshistoriek).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService      AS ArtikelBE   NO-UNDO.
        DEFINE VARIABLE cArtnr        AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cRemainder    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE iSegCount     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE hResult       AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody         AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems        AS JsonArray   NO-UNDO.
        DEFINE VARIABLE cArtnrFilter  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cOmschrijving AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cGroep        AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cOnderMinimum AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cExternInBew  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE lExternInBew  AS LOGICAL     NO-UNDO.
        DEFINE VARIABLE cLageVoorraad AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE lLageVoorraad AS LOGICAL     NO-UNDO.
        DEFINE VARIABLE iPage         AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize     AS INTEGER     NO-UNDO.
        DEFINE VARIABLE lHasMore      AS LOGICAL     NO-UNDO.

        cRemainder = GetPathRemainder(poRequest).
        iSegCount  = SegmentCount(cRemainder).

        IF iSegCount GE 2 THEN
        DO:
            /* GET /artikel/{artnr}/beschikbaarheid or /artikel/{artnr}/artlog */
            ValidateSubResourceSegment(cRemainder).

            IF iSegCount NE 2 THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                    SUBSTITUTE("Expected /artikel/[artnr]/beschikbaarheid or /artikel/[artnr]/artlog, got &1":u, cRemainder)).
                RETURN 0.
            END.

            cArtnr = ENTRY(1, cRemainder, "/":u).

            IF ENTRY(2, cRemainder, "/":u) EQ "beschikbaarheid":u THEN
            DO:
                RETURN HandleGetBeschikbaarheid(cArtnr).
            END.

            RETURN HandleGetArtlog(poRequest, cArtnr).
        END.

        oService = NEW ArtikelBE().
        cArtnr   = GetArtnrFromPath(poRequest).

        IF cArtnr NE "":u THEN
        DO:
            /* GET /artikel/{artnr} */
            hResult = oService:GetArtikel(cArtnr).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("Artikel &1 not found":u, cArtnr)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        /* GET /artikel (list). QueryParamHelper:GetQueryValue returns "" (never
           the unknown value, ?) when a query param is absent, so "not
           supplied" and "supplied blank" are already handled the same way. */
        cArtnrFilter  = QueryParamHelper:GetQueryValue(poRequest, "artnr":u).
        cOmschrijving = QueryParamHelper:GetQueryValue(poRequest, "omschrijving":u).
        cGroep        = QueryParamHelper:GetQueryValue(poRequest, "groep":u).
        cOnderMinimum = QueryParamHelper:GetQueryValue(poRequest, "onderMinimum":u).
        cExternInBew  = QueryParamHelper:GetQueryValue(poRequest, "externInBewerking":u).

        IF cExternInBew NE "":u AND LOOKUP(cExternInBew, "true,false":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid externInBewerking &1":u, cExternInBew)).
            RETURN 0.
        END.
        lExternInBew = (cExternInBew EQ "true":u).

        cLageVoorraad = QueryParamHelper:GetQueryValue(poRequest, "lageVoorraad":u).

        IF cLageVoorraad NE "":u AND LOOKUP(cLageVoorraad, "true,false":u) EQ 0 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid lageVoorraad &1":u, cLageVoorraad)).
            RETURN 0.
        END.
        lLageVoorraad = (cLageVoorraad EQ "true":u).

        iPage = INTEGER(QueryParamHelper:GetQueryValue(poRequest, "page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(QueryParamHelper:GetQueryValue(poRequest, "pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        IF lLageVoorraad THEN
            hResult = oService:GetArtikelen("":u, "":u, "":u, iPage, iPageSize,
                                             "":u, FALSE, TRUE, OUTPUT lHasMore).
        ELSE
            hResult = oService:GetArtikelen(cArtnrFilter, cOmschrijving, cGroep, iPage, iPageSize,
                                             cOnderMinimum, lExternInBew, FALSE, OUTPUT lHasMore).
        oBody   = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /artikel/{artnr}/beschikbaarheid (FR-4). Combines the
                 ttBeschikbaarheid header and ttBeschikbaarheidComponent
                 detail handles from StockAvailabilityBE into a single JSON
                 object - same combination pattern as the
                 ttBestelling/ttBestellingLijn pair in
                 Luna.Web.LakproductieHandler.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER HandleGetBeschikbaarheid( INPUT pcArtnr AS CHARACTER ):

        DEFINE VARIABLE oService       AS StockAvailabilityBE NO-UNDO.
        DEFINE VARIABLE hHeader        AS HANDLE              NO-UNDO.
        DEFINE VARIABLE hComponenten   AS HANDLE              NO-UNDO.
        DEFINE VARIABLE oHeaderRes     AS JsonObject          NO-UNDO.
        DEFINE VARIABLE oComponentRes  AS JsonObject          NO-UNDO.
        DEFINE VARIABLE oResult        AS JsonObject          NO-UNDO.

        oService = NEW StockAvailabilityBE().
        hHeader  = oService:GetBeschikbaarheid(pcArtnr, OUTPUT hComponenten).

        oHeaderRes    = ResultHandleToJson(hHeader).
        oComponentRes = ResultHandleToJson(hComponenten).

        oResult = oHeaderRes:GetJsonArray("beschikbaarheid":u):GetJsonObject(1).
        oResult:Add("componenten":u, oComponentRes:GetJsonArray("componenten":u)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oResult).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: GET /artikel/{artnr}/artlog (FR-5, paged/filtered movement
                 history).
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE INTEGER HandleGetArtlog( INPUT poRequest AS IWebRequest, INPUT pcArtnr AS CHARACTER ):

        DEFINE VARIABLE oService     AS ArtlogBE   NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject NO-UNDO.
        DEFINE VARIABLE cDatumVan    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cDatumTot    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE dDatumVan    AS DATE       NO-UNDO.
        DEFINE VARIABLE dDatumTot    AS DATE       NO-UNDO.
        DEFINE VARIABLE cBeweging    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iPage        AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPageSize    AS INTEGER    NO-UNDO.
        DEFINE VARIABLE lHasMore     AS LOGICAL    NO-UNDO.

        cDatumVan = QueryParamHelper:GetQueryValue(poRequest, "datumVan":u).
        cDatumTot = QueryParamHelper:GetQueryValue(poRequest, "datumTot":u).
        cBeweging = QueryParamHelper:GetQueryValue(poRequest, "beweging":u).

        IF cDatumVan NE ? AND cDatumVan NE "":u THEN
        DO:
            dDatumVan = DATE(cDatumVan) NO-ERROR.
            IF dDatumVan EQ ? THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid datumVan &1":u, cDatumVan)).
                RETURN 0.
            END.
        END.

        IF cDatumTot NE ? AND cDatumTot NE "":u THEN
        DO:
            dDatumTot = DATE(cDatumTot) NO-ERROR.
            IF dDatumTot EQ ? THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid datumTot &1":u, cDatumTot)).
                RETURN 0.
            END.
        END.

        iPage = INTEGER(QueryParamHelper:GetQueryValue(poRequest, "page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(QueryParamHelper:GetQueryValue(poRequest, "pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        oService = NEW ArtlogBE().
        hResult  = oService:GetArtlog(pcArtnr, iPage, iPageSize, dDatumVan, dDatumTot, cBeweging, OUTPUT lHasMore).
        oBody    = ResultHandleToJson(hResult).

        oBody:Add("page":u, iPage).
        oBody:Add("pageSize":u, iPageSize).
        oBody:Add("hasMore":u, lHasMore).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /artikel (create).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS ArtikelBE  NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.

        oService = NEW ArtikelBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:CreateArtikel(oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: PUT /artikel/{artnr} (update).
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS ArtikelBE  NO-UNDO.
        DEFINE VARIABLE cArtnr   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.

        cArtnr = GetArtnrFromPathOrQuery(poRequest).

        IF cArtnr EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "artnr is required, either as a path segment (/artikel/[artnr]) or a query param (?artnr=...)":u).
            RETURN 0.
        END.

        oService = NEW ArtikelBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateArtikel(cArtnr, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: DELETE /artikel/{artnr}, with the same query-param fallback
                 as PUT (/artikel?artnr=...) for artnr values that don't
                 survive PASOE/Tomcat's path routing/encoding.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS ArtikelBE  NO-UNDO.
        DEFINE VARIABLE cArtnr   AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.

        cArtnr = GetArtnrFromPathOrQuery(poRequest).

        IF cArtnr EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                "artnr is required, either as a path segment (/artikel/[artnr]) or a query param (?artnr=...)":u).
            RETURN 0.
        END.

        oService = NEW ArtikelBE().
        oService:DeleteArtikel(cArtnr).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("artnr":u, cArtnr).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unsupported HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /artikel":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /artikel":u).
        RETURN 0.
    END METHOD.

END CLASS.
