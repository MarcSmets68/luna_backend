/*------------------------------------------------------------------------
    File        : LakproductieHandler.cls
    Purpose     : WebHandler for the "Lakproduktie" overview - exposes a
                  single flat list ({"items": [...]}) combining 3 sources
                  (open klantorder-lijnen, open production-line detail
                  records, and min-max stock re-order advice) that need
                  external coating (lak/anodizing) attention, discriminated
                  by a `bron` field with values "lopende-orders" /
                  "lopende-productielijnen" / "min-max-voorraad". Fields
                  that don't apply to a row's `bron` serialize as JSON
                  null. See Luna.BusinessLogic.LakproductieBE for the full
                  field list and business rules (reworked 2026-08-17 to
                  port N:\LunaV12\ExportLakProductie.w 1:1).
                  Also exposes POST /web/lakproduktie/bestelling to create
                  a purchase order (with its lines) from a confirmed
                  bestelling-preview - see
                  Luna.BusinessLogic.LakproductieBestellingBE for that
                  logic. That POST also invalidates the GET-side cache
                  (Luna.BusinessLogic.LakproductieCacheService) on success,
                  so the just-ordered bonlijn/bonlijn_productie doesn't keep
                  showing as still open in the overview until the next
                  scheduled cache refresh.
    Syntax      : GET  /web/lakproduktie
                  POST /web/lakproduktie/bestelling
    Description : Thin WebHandler only - no business logic here. All data
                  access and filtering lives in Luna.BusinessLogic.LakproductieBE
                  (GET) / Luna.BusinessLogic.LakproductieBestellingBE (POST
                  .../bestelling). GET response shape is unchanged by the
                  2026-08-17 rework - this handler still just serializes
                  whatever JSON Luna.BusinessLogic.LakproductieCacheService
                  returns (which itself wraps GetOpenLakproductieItems()
                  behind an on-disk cache refreshed every 5 minutes - see
                  that class and Backend/README.md "Lakproduktie-cache" -
                  since a live recompute takes up to ~1 minute).
    Author(s)   : Devin
    Created     : 2026-08-10
    Reworked    : 2026-08-17
    Updated     : 2026-08-18 - added POST .../bestelling (create purchase
                  order from the Lakproduktie bestelling-preview).
    Updated     : 2026-08-19 - GET now served from
                  Luna.BusinessLogic.LakproductieCacheService's cache
                  instead of recomputing live on every request.
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LakproductieCacheService.
USING Luna.BusinessLogic.LakproductieBestellingBE.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LakproductieHandler INHERITS WebHandler:

    /* URI mapping in openedge.properties is "/lakproduktie" with the
       implicit trailing wildcard, so this also matches
       "/lakproduktie/bestelling". This constant is the mount point we
       strip off PathInfo to find the remaining path segment(s). */
    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/lakproduktie":u.

    /*------------------------------------------------------------------------------
        Purpose: Extracts the path segment(s) (if any) after the mount
                 point, e.g. "/lakproduktie/bestelling" -> "bestelling",
                 "/lakproduktie" or "/lakproduktie/" -> "".
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
        Purpose: Serializes a temp-table result handle to a JsonObject.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
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
        Purpose: Maps an AppError raised by LakproductieBestellingBE
                 (400/404) to an HTTP status code, defaulting unrecognized
                 codes to 500 so no ABL stack trace ever leaks to the
                 client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Default handler for the HTTP GET method. Returns the open
                 lak/anodizing overview as JSON: { "items": [ ... ] }.
        Notes  : Served from Luna.BusinessLogic.LakproductieCacheService's
                 on-disk cache (refreshed every 5 minutes by a scheduled
                 task - see Backend/README.md "Lakproduktie-cache") rather
                 than recomputing the (up to ~1 minute) overview on every
                 request. The cache service itself falls back to a live
                 recompute when there's no cache yet, so this always
                 returns a result either way.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oCacheService AS LakproductieCacheService NO-UNDO.
        DEFINE VARIABLE oBody         AS JsonObject               NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oCacheService = NEW LakproductieCacheService().
        oBody         = oCacheService:GetItems().

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: POST /lakproduktie/bestelling - creates a purchase order
                 (with its lines) from a confirmed Lakproduktie
                 bestelling-preview. See
                 Luna.BusinessLogic.LakproductieBestellingBE:CreateBestelling
                 for the request/response shape and business rules.
        Notes  : On success, invalidates the GET-side cache (see
                 Luna.BusinessLogic.LakproductieCacheService) so the next
                 GET /lakproduktie reflects the bonlijn/bonlijn_productie
                 `besteld` bump this just made, instead of a stale snapshot
                 up to 5 minutes old.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService      AS LakproductieBestellingBE NO-UNDO.
        DEFINE VARIABLE oCacheService AS LakproductieCacheService NO-UNDO.
        DEFINE VARIABLE cRemainder    AS CHARACTER                NO-UNDO.
        DEFINE VARIABLE oReqBody      AS JsonObject                NO-UNDO.
        DEFINE VARIABLE hHeader       AS HANDLE                    NO-UNDO.
        DEFINE VARIABLE hLines        AS HANDLE                    NO-UNDO.
        DEFINE VARIABLE oHeaderRes    AS JsonObject                NO-UNDO.
        DEFINE VARIABLE oLinesRes     AS JsonObject                NO-UNDO.
        DEFINE VARIABLE oOrderJson    AS JsonObject                NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRemainder = GetPathRemainder(poRequest).

        IF cRemainder NE "bestelling":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest),
                SUBSTITUTE("Expected /lakproduktie/bestelling, got /lakproduktie/&1":u, cRemainder)).
            RETURN 0.
        END.

        oReqBody = GetJsonBody(poRequest).

        oService = NEW LakproductieBestellingBE().
        hHeader  = oService:CreateBestelling(oReqBody, OUTPUT hLines).

        oCacheService = NEW LakproductieCacheService().
        oCacheService:InvalidateCache().

        oHeaderRes = ResultHandleToJson(hHeader).
        oLinesRes  = ResultHandleToJson(hLines).

        oOrderJson = oHeaderRes:GetJsonArray("items":u):GetJsonObject(1).
        oOrderJson:Add("lines":u, oLinesRes:GetJsonArray("lines":u)).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oOrderJson).

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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /lakproduktie":u).
        RETURN 0.
    END METHOD.

    /*------------------------------------------------------------------------------
        Purpose: Handler for unimplemented HTTP methods on this endpoint.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /lakproduktie":u).
        RETURN 0.
    END METHOD.

END CLASS.
