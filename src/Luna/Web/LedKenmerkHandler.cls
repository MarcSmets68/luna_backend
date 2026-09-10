/*------------------------------------------------------------------------
    File        : LedKenmerkHandler.cls
    Purpose     : WebHandler exposing CRUD for the "led_kenmerk" table.
    Syntax      : GET    /web/led-kenmerk               - list (paged/filtered)
                  GET    /web/led-kenmerk/{kode}         - get one
                  POST   /web/led-kenmerk                - create (client-supplied kode)
                  PUT    /web/led-kenmerk/{kode}          - update (no-op: kode is the only field)
                  DELETE /web/led-kenmerk/{kode}          - delete (409 if referenced by artikel.led-kenmerk)
    Description : Thin WebHandler only - no business logic/DB access here.
                  All of that lives in Luna.BusinessLogic.LedKenmerkBE.
    Author(s)   : Devin
    Created     : 2026-08-29
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LedKenmerkBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedKenmerkHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-kenmerk":u.

    METHOD PRIVATE CHARACTER GetKeyFromPath( INPUT poRequest AS IWebRequest ):

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

    METHOD PRIVATE JsonObject GetJsonBody( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oEntity AS Progress.Lang.Object NO-UNDO.

        oEntity = poRequest:Entity.

        IF NOT VALID-OBJECT(oEntity) OR NOT TYPE-OF(oEntity, JsonObject) THEN
            UNDO, THROW NEW Progress.Lang.AppError("Request body must be a JSON object":u, 400).

        RETURN CAST(oEntity, JsonObject).

        CATCH oError AS Progress.Lang.Error:
            IF TYPE-OF(oError, Progress.Lang.AppError) THEN
                UNDO, THROW oError.

            UNDO, THROW NEW Progress.Lang.AppError(
                SUBSTITUTE("Malformed JSON request body: &1":u, oError:GetMessage(1)), 400).
        END CATCH.

    END METHOD.

    METHOD PRIVATE JsonObject ResultHandleToJson( INPUT phResult AS HANDLE ):

        DEFINE VARIABLE lcJson  AS LONGCHAR          NO-UNDO.
        DEFINE VARIABLE oParser AS ObjectModelParser NO-UNDO.

        phResult:WRITE-JSON("LONGCHAR":u, lcJson, TRUE).

        oParser = NEW ObjectModelParser().

        RETURN CAST(oParser:Parse(lcJson), JsonObject).

    END METHOD.

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

    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService    AS LedKenmerkBE NO-UNDO.
        DEFINE VARIABLE cKode       AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE hResult     AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody       AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems      AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iPage       AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize   AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cKodeFilter AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cKodePrefix AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE lHasMore    AS LOGICAL     NO-UNDO.

        oService = NEW LedKenmerkBE().
        cKode    = GetKeyFromPath(poRequest).

        IF cKode NE "":u THEN
        DO:
            hResult = oService:GetItem(cKode).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("led_kenmerk &1 not found":u, cKode)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cKodeFilter = poRequest:URI:GetQueryValue("kode":u).
        IF cKodeFilter EQ ? THEN cKodeFilter = "":u.

        cKodePrefix = poRequest:URI:GetQueryValue("kodePrefix":u).
        IF cKodePrefix EQ ? THEN cKodePrefix = "":u.

        hResult = oService:GetItems(iPage, iPageSize, cKodeFilter, cKodePrefix, OUTPUT lHasMore).
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

    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LedKenmerkBE NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject   NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE       NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject   NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray    NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER    NO-UNDO.

        oService = NEW LedKenmerkBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("kode":u) OR TRIM(oReqBody:GetCharacter("kode":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode is required":u).
            RETURN 0.
        END.

        cKode = oReqBody:GetCharacter("kode":u).

        hResult = oService:CreateItem(cKode).
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
        Purpose: PUT /led-kenmerk/{kode}. kode is the only field this table has
                 and it is immutable (path segment only) - so a PUT is a no-op
                 that just re-returns the current row after confirming it
                 exists. Any body content (including a kode field) is ignored.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LedKenmerkBE NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray   NO-UNDO.

        cKode = GetKeyFromPath(poRequest).

        IF cKode EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode path segment is required, e.g. /led-kenmerk/K1":u).
            RETURN 0.
        END.

        /* Body is intentionally not read/applied - see method header. */
        oService = NEW LedKenmerkBE().
        hResult  = oService:GetItem(cKode).
        oBody    = ResultHandleToJson(hResult).
        oItems   = oBody:GetJsonArray("items":u).

        IF oItems:Length EQ 0 THEN
            WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("led_kenmerk &1 not found":u, cKode)).
        ELSE
            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS LedKenmerkBE NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject  NO-UNDO.

        cKode = GetKeyFromPath(poRequest).

        IF cKode EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode path segment is required, e.g. /led-kenmerk/K1":u).
            RETURN 0.
        END.

        oService = NEW LedKenmerkBE().
        oService:DeleteItem(cKode).

        oBody = NEW JsonObject().
        oBody:Add("status":u, "deleted":u).
        oBody:Add("kode":u, cKode).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-kenmerk":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-kenmerk":u).
        RETURN 0.
    END METHOD.

END CLASS. 
