/*------------------------------------------------------------------------
    File        : LedRALHandler.cls
    Purpose     : WebHandler exposing read-only access to the "led_RAL" table.
    Syntax      : GET  /web/led-ral               - list (paged, optional
                                                      omschrijvingPrefix filter)
                  GET  /web/led-ral/{ral}          - get one
                  POST/PUT/DELETE                  - 405 Method Not Allowed
                  (led_RAL is an industry-standard RAL color reference table -
                  no CRUD-write need was raised for it, see architect decision
                  in docs/architecture/coating-fase1-afronding-ontwerp.md
                  sectie 2.1/2.3)
    Description : Thin WebHandler only - no business logic/DB access here.
                  All of that lives in Luna.BusinessLogic.LedRALBE.
    Author(s)   : Devin (backend-coder)
    Created     : 2026-09-20
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Progress.Json.ObjectModel.JsonArray.
USING Progress.Json.ObjectModel.ObjectModelParser.
USING Luna.BusinessLogic.LedRALBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.LedRALHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/led-ral":u.

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

        DEFINE VARIABLE oService            AS LedRALBE   NO-UNDO.
        DEFINE VARIABLE cKey                AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE iRal                AS INTEGER    NO-UNDO.
        DEFINE VARIABLE hResult             AS HANDLE     NO-UNDO.
        DEFINE VARIABLE oBody               AS JsonObject NO-UNDO.
        DEFINE VARIABLE oItems              AS JsonArray  NO-UNDO.
        DEFINE VARIABLE iPage               AS INTEGER    NO-UNDO.
        DEFINE VARIABLE iPageSize           AS INTEGER    NO-UNDO.
        DEFINE VARIABLE cOmschrijvingPrefix AS CHARACTER  NO-UNDO.
        DEFINE VARIABLE lHasMore            AS LOGICAL    NO-UNDO.

        oService = NEW LedRALBE().
        cKey     = GetKeyFromPath(poRequest).

        IF cKey NE "":u THEN
        DO:
            iRal = INTEGER(cKey) NO-ERROR.
            IF iRal EQ ? OR ERROR-STATUS:ERROR THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Invalid ral &1":u, cKey)).
                RETURN 0.
            END.

            hResult = oService:GetItem(iRal).
            oBody   = ResultHandleToJson(hResult).
            oItems  = oBody:GetJsonArray("items":u).

            IF oItems:Length EQ 0 THEN
                WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), SUBSTITUTE("led_RAL &1 not found":u, iRal)).
            ELSE
                WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oItems:GetJsonObject(1)).

            RETURN 0.
        END.

        iPage = INTEGER(poRequest:URI:GetQueryValue("page":u)) NO-ERROR.
        IF iPage EQ ? OR iPage LT 1 THEN iPage = 1.

        iPageSize = INTEGER(poRequest:URI:GetQueryValue("pageSize":u)) NO-ERROR.
        IF iPageSize EQ ? OR iPageSize LT 1 THEN iPageSize = 25.
        IF iPageSize GT 200 THEN iPageSize = 200.

        cOmschrijvingPrefix = poRequest:URI:GetQueryValue("omschrijvingPrefix":u).
        IF cOmschrijvingPrefix EQ ? THEN cOmschrijvingPrefix = "":u.

        hResult = oService:GetItems(iPage, iPageSize, cOmschrijvingPrefix, OUTPUT lHasMore).
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
        Purpose: led_RAL is read-only through this API (see class header) -
                 POST/PUT/DELETE are deliberately not implemented as CRUD
                 operations, they always return 405.
    ------------------------------------------------------------------------------*/
    METHOD OVERRIDE PROTECTED INTEGER HandlePost( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "led_RAL is read-only - POST is not supported on /led-ral":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandlePut( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "led_RAL is read-only - PUT is not supported on /led-ral":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleDelete( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "led_RAL is read-only - DELETE is not supported on /led-ral":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /led-ral":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /led-ral":u).
        RETURN 0.
    END METHOD.

END CLASS.
