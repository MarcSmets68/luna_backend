/*------------------------------------------------------------------------ 
    File        : DevUsersHandler.cls 
    Purpose     : DEV/DEBUG WebHandler exposing a flat list of gebruiker 
                  rows for backend connectivity verification during development. 
                  Deliberately namespaced under /web/dev-users (not /web/users) 
                  to make clear this is not a production user-management endpoint. 
    Syntax      : GET /web/dev-users 
    Description : Thin WebHandler only - routing, response assembly and 
                  formatting. No business logic and no direct DB access - 
                  all of that lives in Luna.BusinessLogic.DevUsersBE. 
    Author(s)   : Devin 
    Created     : 2026-08-12 
  ----------------------------------------------------------------------*/ 
 
USING Progress.Lang.*. 
USING OpenEdge.Web.WebResponseWriter. 
USING OpenEdge.Net.HTTP.StatusCodeEnum. 
USING OpenEdge.Web.WebHandler. 
USING OpenEdge.Web.IWebRequest. 
USING Progress.Json.ObjectModel.JsonObject. 
USING Progress.Json.ObjectModel.ObjectModelParser. 
USING Luna.BusinessLogic.DevUsersBE. 
USING Luna.BusinessLogic.AuthGuard.
 
BLOCK-LEVEL ON ERROR UNDO, THROW. 
 
CLASS Luna.Web.DevUsersHandler INHERITS WebHandler: 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Serializes a result handle (from DevUsersBE) to a 
                 JsonObject shaped as "items": [...] per the temp-table
                 SERIALIZE-NAME. 
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
        Purpose: GET /dev-users - returns {"items": [...]} with kode/naam/ 
                 email/niveau/passief per gebruiker row. 
    ------------------------------------------------------------------------------*/ 
    METHOD OVERRIDE PROTECTED INTEGER HandleGet( INPUT poRequest AS IWebRequest ): 
 
        DEFINE VARIABLE oService AS DevUsersBE NO-UNDO. 
        DEFINE VARIABLE hUsers   AS HANDLE     NO-UNDO. 
        DEFINE VARIABLE oBody    AS JsonObject NO-UNDO. 
 
        IF NOT DevUsersBE:IsEnabled() THEN
        DO:
            WriteErrorResponse(INTEGER(StatusCodeEnum:NotFound), "Niet gevonden":u).
            RETURN 0.
        END.

        IF NOT AuthGuard:Check(poRequest) THEN
            RETURN 0.

        oService = NEW DevUsersBE(). 
        hUsers   = oService:GetUsers(). 
 
        oBody = ResultHandleToJson(hUsers). 
 
        WriteJsonResponse(INTEGER(StatusCodeEnum:OK), oBody). 
 
        RETURN 0. 
 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Handler for unsupported HTTP methods on this endpoint. 
    ------------------------------------------------------------------------------*/ 
    METHOD OVERRIDE PROTECTED INTEGER HandleNotAllowedMethod( INPUT poRequest AS IWebRequest ): 
        WriteErrorResponse(INTEGER(StatusCodeEnum:MethodNotAllowed), "Method not allowed on /dev-users":u). 
        RETURN 0. 
    END METHOD. 
 
    /*------------------------------------------------------------------------------ 
        Purpose: Handler for unimplemented HTTP methods on this endpoint. 
    ------------------------------------------------------------------------------*/ 
    METHOD OVERRIDE PROTECTED INTEGER HandleNotImplemented( INPUT poRequest AS IWebRequest ): 
        WriteErrorResponse(INTEGER(StatusCodeEnum:NotImplemented), "Method not implemented on /dev-users":u). 
        RETURN 0. 
    END METHOD. 
 
END CLASS. 
