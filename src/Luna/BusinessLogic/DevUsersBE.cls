/*------------------------------------------------------------------------ 
    File        : DevUsersBE.cls 
    Purpose     : DEV/DEBUG VERIFICATION ENTITY ONLY. Returns a flat list of 
                  gebruiker rows (kode/naam/email/niveau/passief) so the 
                  dev-users endpoint can be used to sanity-check backend 
                  connectivity during development. 
                  Do NOT extend this class with create/update/delete 
                  methods and do NOT wire it into authentication - it is 
                  not a general-purpose UserBE. Password must NEVER be 
                  read or returned by this class - no method here may 
                  reference gebruiker.Password. 
    Syntax      : Called from Luna.Web.DevUsersHandler (GET /web/dev-users) 
    Description : Owns all DB access for this feature - no direct DB access 
                  is allowed from the WebHandler layer. NO-LOCK reads only. 
    Author(s)   : Devin 
    Created     : 2026-08-12 
  ----------------------------------------------------------------------*/ 
 
USING Progress.Lang.*. 
 
BLOCK-LEVEL ON ERROR UNDO, THROW. 
 
CLASS Luna.BusinessLogic.DevUsersBE: 
 
    DEFINE TEMP-TABLE ttUser NO-UNDO SERIALIZE-NAME "items":u
        FIELD kode    AS CHARACTER SERIALIZE-NAME "kode":u
        FIELD naam    AS CHARACTER SERIALIZE-NAME "naam":u
        FIELD email   AS CHARACTER SERIALIZE-NAME "email":u
        FIELD niveau  AS INTEGER   SERIALIZE-NAME "niveau":u
        FIELD passief AS LOGICAL   SERIALIZE-NAME "passief":u.
 
    /*------------------------------------------------------------------------------ 
        Purpose: Returns all gebruiker rows, sorted by kode. Only 
                 kode/naam/email/niveau/passief are copied - gebruiker.Password 
                 is never referenced here. 
    ------------------------------------------------------------------------------*/ 
    METHOD PUBLIC HANDLE GetUsers(): 
 
        EMPTY TEMP-TABLE ttUser. 
 
        FOR EACH gebruiker NO-LOCK BY gebruiker.kode: 
 
            CREATE ttUser. 
            ASSIGN 
                ttUser.kode    = IF gebruiker.kode  EQ ? THEN "":u ELSE gebruiker.kode
                ttUser.naam    = IF gebruiker.naam  EQ ? THEN "":u ELSE gebruiker.naam
                ttUser.email   = IF gebruiker.email EQ ? THEN "":u ELSE gebruiker.email
                ttUser.niveau  = IF gebruiker.niveau  EQ ? THEN 0     ELSE gebruiker.niveau
                ttUser.passief = IF gebruiker.passief EQ ? THEN FALSE ELSE gebruiker.passief
                . 
        END. 
 
        RETURN TEMP-TABLE ttUser:HANDLE. 
 
    END METHOD. 
 
END CLASS. 
