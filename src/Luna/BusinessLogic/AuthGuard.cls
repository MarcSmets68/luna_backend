/*------------------------------------------------------------------------
    File        : AuthGuard.cls
    Purpose     : Reusable token guard for WebHandlers. Reads the session
                  token from the X-Auth-Token header, validates it through
                  AuthBE:ValidateToken and - depending on the AUTH_ENFORCE
                  feature flag - either rejects the request with a 401 or
                  only logs a warning and lets it through.
    Syntax      : Call at the top of every HandleGet/HandlePost/HandlePut/
                  HandleDelete override (WebHandler:HandleRequest() takes no
                  request parameter, so it cannot be overridden for this):
                      IF NOT AuthGuard:Check(poRequest) THEN
                          RETURN 0.
    Description : AUTH_ENFORCE is an OS environment variable, read fresh on
                  every call (same idiom as AUTH_EVERYONE_ADMIN in AuthBE).
                  Anything other than exactly "true" (case-insensitive) is
                  FALSE = warn-only mode, so the frontend can start sending
                  the token before enforcement is switched on.
                  The standard Authorization header is intercepted by
                  PASOE/Tomcat, hence the custom X-Auth-Token header (see
                  Luna.Web.LogoutHandler).
                  The guard deliberately exposes neither kode nor niveau:
                  authorization per niveau is NOT part of this guard.
                  CORS preflight (OPTIONS) requests carry no token and are
                  always let through.
    Author(s)   : Devin
    Created     : 2026-10-15
  ----------------------------------------------------------------------*/

USING Progress.Lang.*.
USING OpenEdge.Web.IWebRequest.
USING OpenEdge.Web.WebResponse.
USING OpenEdge.Web.WebResponseWriter.
USING OpenEdge.Net.HTTP.StatusCodeEnum.
USING OpenEdge.Net.HTTP.HttpHeader.
USING Progress.Json.ObjectModel.JsonObject.
USING Luna.BusinessLogic.AuthBE.

BLOCK-LEVEL ON ERROR UNDO, THROW.

CLASS Luna.BusinessLogic.AuthGuard:

    /* Reads the AUTH_ENFORCE OS-environment variable (default FALSE). */
    METHOD PUBLIC STATIC LOGICAL IsEnforced():

        DEFINE VARIABLE cFlag AS CHARACTER NO-UNDO.

        cFlag = OS-GETENV("AUTH_ENFORCE":u).

        IF cFlag EQ ? THEN
            RETURN FALSE.

        RETURN UPPER(TRIM(cFlag)) EQ "TRUE":u.

    END METHOD.

    /* Extracts the session token from the X-Auth-Token header.
       Returns "":u if the header is absent/blank. */
    METHOD PRIVATE STATIC CHARACTER GetAuthToken( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE oHeader AS HttpHeader NO-UNDO.
        DEFINE VARIABLE cValue  AS CHARACTER  NO-UNDO.

        IF NOT poRequest:HasHeader("X-Auth-Token":u) THEN
            RETURN "":u.

        oHeader = CAST(poRequest:GetHeader("X-Auth-Token":u), HttpHeader).
        cValue  = oHeader:Value.

        IF cValue EQ ? THEN
            RETURN "":u.

        RETURN TRIM(cValue).

    END METHOD.

    /* Writes the 401 in the standard error format
       {"error": {"message": ..., "code": 401}} - same as the handlers. */
    METHOD PRIVATE STATIC VOID WriteUnauthorized( INPUT pcMessage AS CHARACTER ):

        DEFINE VARIABLE oError    AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oBody     AS JsonObject  NO-UNDO.
        DEFINE VARIABLE oResponse AS WebResponse NO-UNDO.
        DEFINE VARIABLE oWriter   AS WebResponseWriter NO-UNDO.

        oError = NEW JsonObject().
        oError:Add("message":u, pcMessage).
        oError:Add("code":u, INTEGER(StatusCodeEnum:Unauthorized)).

        oBody = NEW JsonObject().
        oBody:Add("error":u, oError).

        ASSIGN
            oResponse             = NEW WebResponse()
            oResponse:StatusCode  = INTEGER(StatusCodeEnum:Unauthorized)
            oResponse:Entity      = oBody
            oResponse:ContentType = "application/json":u
            .

        oWriter = NEW WebResponseWriter(oResponse).
        oWriter:Open().
        oWriter:Close().

    END METHOD.

    /* Validates the request's X-Auth-Token.
       Returns TRUE  = the handler may continue (valid token, OPTIONS
                       preflight, or AUTH_ENFORCE is not "true").
               FALSE = a 401 response has already been written; the caller
                       must stop and RETURN 0.
       Never logs the token value itself. */
    METHOD PUBLIC STATIC LOGICAL Check( INPUT poRequest AS IWebRequest ):

        DEFINE VARIABLE cToken  AS CHARACTER NO-UNDO.
        DEFINE VARIABLE cKode   AS CHARACTER NO-UNDO.
        DEFINE VARIABLE iNiveau AS INTEGER   NO-UNDO.
        DEFINE VARIABLE lValid  AS LOGICAL   NO-UNDO INITIAL FALSE.
        DEFINE VARIABLE cReason AS CHARACTER NO-UNDO.
        DEFINE VARIABLE oAuthBE AS AuthBE    NO-UNDO.

        IF poRequest:Method EQ "OPTIONS":u THEN
            RETURN TRUE.

        cToken = GetAuthToken(poRequest).

        IF cToken EQ "":u THEN
            cReason = "ontbrekende token":u.
        ELSE
        DO ON ERROR UNDO, LEAVE:
            oAuthBE = NEW AuthBE().
            lValid  = oAuthBE:ValidateToken(cToken, OUTPUT cKode, OUTPUT iNiveau).
            CATCH oError AS Progress.Lang.Error:
                lValid = FALSE.
            END CATCH.
        END.

        IF lValid THEN
            RETURN TRUE.

        IF cReason EQ "":u THEN
            cReason = "ongeldige of verlopen token":u.

        IF IsEnforced() THEN
        DO:
            LOG-MANAGER:WRITE-MESSAGE(
                SUBSTITUTE("AuthGuard: &1 &2 geweigerd (&3)":u,
                           poRequest:Method, poRequest:PathInfo, cReason), "AuthGuard":u).
            WriteUnauthorized("Ongeldige of verlopen sessie":u).
            RETURN FALSE.
        END.

        LOG-MANAGER:WRITE-MESSAGE(
            SUBSTITUTE("AuthGuard WARNING (AUTH_ENFORCE=false, verzoek toegelaten): &1 &2 - &3":u,
                       poRequest:Method, poRequest:PathInfo, cReason), "AuthGuard":u).

        RETURN TRUE.

    END METHOD.

END CLASS.
