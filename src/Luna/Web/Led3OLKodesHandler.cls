/*------------------------------------------------------------------------
    File        : Led3OLKodesHandler.cls
    Purpose     : WebHandler exposing CRUD for led_3OL_kodes.
    Syntax      : GET    /web/led-3ol-kodes             - list (paged/filtered - kode/kodePrefix + artnr)
                  GET    /web/led-3ol-kodes/{kode}        - get one
                  POST   /web/led-3ol-kodes               - create (404 if artnr not in artikel, 409 on kode collision)
                  PUT    /web/led-3ol-kodes/{kode}         - update (artnr/comp/excelKode/samenstellingKode)
                  DELETE /web/led-3ol-kodes/{kode}         - delete
    Description : Thin WebHandler only - all DB access/business logic lives
                  in Luna.BusinessLogic.Led3OLKodesBE.
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
USING Luna.BusinessLogic.Led3OLKodesBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.Led3OLKodesHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-3ol-kodes":u.

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

        DEFINE VARIABLE oService     AS Led3OLKodesBE NO-UNDO.
        DEFINE VARIABLE cKode        AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE hResult      AS HANDLE      NO-UNDO.
        DEFINE VARIABLE oBody        AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oItems       AS JsonArray   NO-UNDO.
        DEFINE VARIABLE iPage        AS INTEGER     NO-UNDO.
        DEFINE VARIABLE iPageSize    AS INTEGER     NO-UNDO.
        DEFINE VARIABLE cKodeFilter  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cKodePrefix  AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE cArtnrFilter AS CHARACTER   NO-UNDO.
        DEFINE VARIABLE lHasMore     AS LOGICAL     NO-UNDO.

        oService = NEW Led3OLKodesBE().
        cKode    = GetKeyFromPath(poRequest).

        IF cKode NE "":u THEN
        DO:
            hResult = oService:GetItem(cKode).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("led_3OL_kodes &1 not found":u, cKode)).
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

        cArtnrFilter = poRequest:URI:GetQueryValue("artnr":u).
        IF cArtnrFilter EQ ? THEN cArtnrFilter = "":u.

        hResult = oService:GetItems(iPage, iPageSize, cKodeFilter, cKodePrefix, cArtnrFilter, OUTPUT lHasMore).
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

        DEFINE VARIABLE oService AS Led3OLKodesBE NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE cArtnr   AS CHARACTER  NO-UNDO.

        oService = NEW Led3OLKodesBE().
        oReqBody = GetJsonBody(poRequest).

        IF NOT oReqBody:Has("kode":u) OR TRIM(oReqBody:GetCharacter("kode":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode is required":u).
            RETURN 0.
        END.
        IF NOT oReqBody:Has("artnr":u) OR TRIM(oReqBody:GetCharacter("artnr":u)) EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "artnr is required":u).
            RETURN 0.
        END.

        ASSIGN
            cKode  = oReqBody:GetCharacter("kode":u)
            cArtnr = oReqBody:GetCharacter("artnr":u)
            .

        hResult = oService:CreateItem(cKode, cArtnr, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:Created), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS Led3OLKodesBE NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oReqBody AS JsonObject NO-UNDO.
        DEFINE VARIABLE hResult  AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems   AS JsonArray  NO-UNDO.

        cKode = GetKeyFromPath(poRequest).

        IF cKode EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode path segment is required, e.g. /led-3ol-kodes/K1":u).
            RETURN 0.
        END.

        oService = NEW Led3OLKodesBE().
        oReqBody = GetJsonBody(poRequest).

        hResult = oService:UpdateItem(cKode, oReqBody).
        oBody   = ResultHandleToJson(hResult).
        oItems  = oBody:GetJsonArray("items":u).

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oService AS Led3OLKodesBE NO-UNDO.
        DEFINE VARIABLE cKode    AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO.

        cKode = GetKeyFromPath(poRequest).

        IF cKode EQ "":u THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "kode path segment is required, e.g. /led-3ol-kodes/K1":u).
            RETURN 0.
        END.

        oService = NEW Led3OLKodesBE().
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
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-3ol-kodes":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-3ol-kodes":u).
        RETURN 0.
    END METHOD.

END CLASS. 
