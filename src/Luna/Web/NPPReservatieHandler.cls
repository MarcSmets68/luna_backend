/*------------------------------------------------------------------------
    File        : NPPReservatieHandler.cls
    Purpose     : Thin WebHandler for the NPP "Reservaties" tile (read-only).
                  Syntax    : GET /npp/reservaties?mode=direct|productie
                              GET /npp/reservaties/{bonnr}?groepnr=<int>
                  Single handler mapped to the /npp/reservaties prefix,
                  routing internally on the remaining path segments -
                  mirrors the established pattern for multi-route NPP/Bon
                  handlers (e.g. Luna.Web.BonHandler, one mapping for
                  /bon and all of its sub-routes; Luna.Web.
                  NPPKwaliteitscontroleHandler, one mapping for its whole
                  family of sub-routes) rather than one handler class per
                  sub-route, since PASOE's handler mapping is a single
                  prefix match per class, not a per-route registration.
                  All logic lives in Luna.BusinessLogic.NPPReservatieBE.
                  Read-only, no auth (same as the other read-only NPP tiles).
    Author(s)   : Devin
    Created     : 2026-09-18
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Web.WebHandler.
USING OpenEdge.Web.IWebRequest.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.NPPReservatieBE.
USING Luna.Web.Util.QueryParamHelper.
USING Luna.BusinessLogic.AuthGuard.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.Web.NPPReservatieHandler INHERITS WebHandler:

    DEFINE PRIVATE VARIABLE cMountPoint AS CHARACTER NO-UNDO INITIAL "/npp/reservaties":u.

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
        Purpose: Maps an AppError raised by NPPReservatieBE (400/404) to
                 an HTTP status code, defaulting unrecognized codes to 500
                 so no ABL stack trace ever leaks to the client.
    ------------------------------------------------------------------------------*/
    METHOD PRIVATE VOID HandleAppError( INPUT poError AS Progress.Lang.AppError ):

        DEFINE VARIABLE iStatus AS INTEGER NO-UNDO.

        iStatus = poError:GetMessageNum(1).

        IF LOOKUP(STRING(iStatus), "400,404,409":u) EQ 0 THEN
            iStatus = INTEGER(StatusCodeEnum:InternalServerError).

        WriteErrorResponse(iStatus, poError:GetMessage(1)).

    END METHOD.

    /* Path remainder after the mount point, e.g. "" for the queue,
       "20345" for the detail route. */
    METHOD PRIVATE CHARACTER GetPathRemainder( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cPathInfo AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cRest     AS CHARACTER NO-UNDO.

        cPathInfo = poRequest:PathInfo.

        IF cPathInfo BEGINS cMountPoint THEN
            cRest = SUBSTRING(cPathInfo, LENGTH(cMountPoint) + 1).
        ELSE
            cRest = cPathInfo.

        RETURN TRIM(cRest, "/":u).

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cRest     AS CHARACTER       NO-UNDO.
        DEFINE VARIABLE cMode     AS CHARACTER       NO-UNDO.
        DEFINE VARIABLE cGroepnr  AS CHARACTER       NO-UNDO.
        DEFINE VARIABLE iBonnr    AS INTEGER         NO-UNDO.
        DEFINE VARIABLE iGroepnr  AS INTEGER         NO-UNDO INITIAL 0.
        DEFINE VARIABLE oService  AS NPPReservatieBE NO-UNDO.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        cRest = GetPathRemainder(poRequest).
        oService = NEW NPPReservatieBE().

        IF cRest EQ "":u THEN
        DO:
            /* GET /npp/reservaties?mode=direct|productie */
            cMode = TRIM(QueryParamHelper:GetQueryValue(poRequest, "mode":u)).
            IF cMode EQ "":u OR cMode EQ ? THEN
                cMode = "direct":u.

            WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oService:GetQueue(cMode)).
            RETURN 0.
        END.

        IF NUM-ENTRIES(cRest, "/":u) NE 1 THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), "Ongeldig pad":u).
            RETURN 0.
        END.

        /* GET /npp/reservaties/{bonnr}?groepnr=<int> */
        /* INTEGER() NO-ERROR returns 0 (not ?) on failure - check ERROR-STATUS */
        iBonnr = INTEGER(cRest) NO-ERROR.
        IF ERROR-STATUS:ERROR THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Ongeldig bonnr '&1'":u, cRest)).
            RETURN 0.
        END.

        cGroepnr = TRIM(QueryParamHelper:GetQueryValue(poRequest, "groepnr":u)).
        IF cGroepnr NE "":u AND cGroepnr NE ? THEN
        DO:
            iGroepnr = INTEGER(cGroepnr) NO-ERROR.
            IF ERROR-STATUS:ERROR THEN
            DO:
                WriteErrorResponse(INTEGER(StatusCodeEnum:BadRequest), SUBSTITUTE("Ongeldig groepnr '&1'":u, cGroepnr)).
                RETURN 0.
            END.
        END.

        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oService:GetDetail(iBonnr, iGroepnr)).
        RETURN 0.

        CATCH oAppError AS Progress.Lang.AppError:
            HandleAppError(oAppError).
            RETURN 0.
        END CATCH.

    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /npp/reservaties":u).
        RETURN 0.
    END METHOD.

    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ):
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /npp/reservaties":u).
        RETURN 0.
    END METHOD.

END CLASS.
